import XCTest
@testable import VoiceType

// Offline harness: runs the REAL production transcription path (model in
// memory, Metal/CoreML, the actual post-processing chain) over a corpus of
// saved recordings and writes its output as JSONL for scripts/replay-compare.py
// to score. Companion to CorpusDumpTests.swift (post-processing only, no
// whisper) — this one exercises TranscriptionService.transcribe end to end.
//
// Why a test and not a CLI target: same reasoning as CorpusDumpTests — the
// package ships a single executable (the app), and a second product would
// drag an eval tool into the release build. A test target already links the
// production code, so the measurement runs against exactly what ships.
//
// Skipped unless VOICETYPE_REPLAY_OUT is set, so CI and ordinary `swift test`
// runs are unaffected. Run in RELEASE with the NATIVE build system, per the
// 2026-09-24 spike (docs/plans/quality-tools.md §3.R1a) and the follow-up
// diagnostic the same day — see `scripts/replay.sh`, which is the supported
// entry point and always passes both flags:
//
//   swift test -c release --build-system native \
//     -Xswiftc -enable-testing -Xswiftc -DDEBUG --filter ReplayHarnessTests
//
// `--build-system native` is NOT cosmetic: the default build system
// (swiftbuild, Xcode 27) ships `SwiftWhisper_whisper_metal.bundle` with a
// precompiled `default.metallib` instead of compiling `ggml-metal.metal`
// from source, and that metallib silently produces near-empty ASR output
// (measured WER 1.0 on Tests/Fixtures/bench under swiftbuild vs 0.00-0.08
// under native — same audio/model/prompt, both CoreML and Metal-only
// policy, since CoreML only replaces the encoder). `build-app.sh` already
// works around this for the shipped app; the harness needs the same flag.
//
// `-DDEBUG` is required even in release: ModelStatusTests uses
// `_testSetModelStatus`/`_testModelLoadGeneration`, which only exist under
// `#if DEBUG`, and the test target won't compile without it. The flag only
// affects VoiceType's own Swift code — whisper.cpp's C/Metal code is already
// optimized regardless.
//
// Privacy: the corpus is the owner's real speech, and the repository is
// public. VOICETYPE_REPLAY_OUT is rejected when it resolves inside the
// repository working tree (see ReplayHarnessTests+Support.swift's
// `resolveOutputURL`), and the file is written with 0600 permissions.
//
// Split across four files, purely for the 600-line file_length warning
// threshold (same reason TranscriptionService gained +PostProcess.swift):
//   - ReplayHarnessTests.swift         — this file: the test driver.
//   - ReplayHarnessTests+Support.swift — pure static helpers.
//   - ReplayHarnessTests+JSONL.swift   — K3 Codable record types.
//   - ReplayHarnessTests+Input.swift   — ReplayInput + its own unit tests
//     (kept adjacent to the harness, per docs/plans/quality-tools.md §3.R1
//     "Отбор входа — чистая функция в том же файле теста").
@MainActor
final class ReplayHarnessTests: XCTestCase {

    // Support types (ReplayHarnessFailure, ResolvedReplayInput,
    // EffectiveSettings, OriginalSettings, RecordOutcome, Comparability,
    // ReplaySummaryCounts, RunContext) live in ReplayHarnessTests+Support.swift
    // — purely for the 600-line file_length warning threshold.

    func testReplay() async throws {
        let env = ProcessInfo.processInfo.environment
        guard let outPath = env["VOICETYPE_REPLAY_OUT"] else {
            throw XCTSkip("VOICETYPE_REPLAY_OUT not set — offline harness only")
        }
        do {
            try await runReplay(env: env, outPath: outPath)
        } catch {
            XCTFail("\(error)")
        }
    }

    // MARK: - Orchestration (each phase kept small for cyclomatic_complexity)

    private func runReplay(env: [String: String], outPath: String) async throws {
        let input = try Self.resolveReplayInput(env: env)
        let outURL = try Self.resolveOutputURLOrFail(outPath)
        let settings = try Self.resolveEffectiveSettings(env: env)

        let original = OriginalSettings(
            language: AppSettings.shared.language,
            vocabulary: AppSettings.shared.customVocabulary,
            normalize: AppSettings.shared.normalizeTranscript,
            removeFillers: AppSettings.shared.removeFillerWords,
            trim: AppSettings.shared.trimWhitespaceAfterInsert,
            selectedModel: AppSettings.shared.selectedModel,
            coreMLMode: AppSettings.shared.coreMLMode
        )
        defer { Self.restore(original) }
        Self.apply(settings)

        // The whisper context must be released with TranscriptionService.shutdown()
        // before this xctest process exits, or ggml aborts at atexit trying to
        // free a live Metal device (see TranscriptionService.shutdown()'s own doc
        // comment — reproduced live here on the first real run: exit signal 6,
        // ggml_metal_device_free ← atexit, with the context still holding a model).
        // A do/catch (not `defer`, which cannot `await`) guarantees shutdown runs
        // on every exit path, success or failure.
        let service = TranscriptionService()
        do {
            try await runReplayBody(
                service: service, input: input, settings: settings, env: env, outURL: outURL
            )
        } catch {
            _ = await service.shutdown()
            throw error
        }
        _ = await service.shutdown()
    }

    private func runReplayBody(
        service: TranscriptionService,
        input: ResolvedReplayInput,
        settings: EffectiveSettings,
        env: [String: String],
        outURL: URL
    ) async throws {
        let (modelURL, modelForCoreML) = try Self.resolveModelURL(env: env, selectedModel: settings.selectedModel)

        let loadStart = ContinuousClock.now
        try await service.loadModel(at: modelURL, language: settings.language, model: modelForCoreML)
        try await Self.waitUntilReady(service)
        let loadMs = Self.durationMs(from: loadStart, to: ContinuousClock.now)

        let (runPipelineStamp, runStampParts) = try Self.verifyEffectiveConfiguration(
            service: service, settings: settings, modelURL: modelURL
        )
        let runModelRawValue = Self.modelRawValue(fromFileName: modelURL.lastPathComponent)
        let coreMLRequested = await Self.computeCoreMLRequested(
            modelForCoreML: modelForCoreML, coreMLMode: settings.coreMLMode
        )
        let context = RunContext(
            mode: input.mode,
            service: service,
            language: settings.language,
            runStampParts: runStampParts,
            runModelRawValue: runModelRawValue
        )

        // Fail-closed before opening the JSONL (P2 review finding): a
        // missing/unparseable Package.resolved pin silently wrote "unknown"
        // into the run header instead of surfacing the problem.
        guard let swiftWhisperRevision = Self.swiftWhisperRevision() else {
            throw ReplayHarnessFailure(
                message: "Could not read the swiftwhisper pin's revision from Package.resolved"
            )
        }

        let handle = try Self.openOutputFile(outURL)
        // Must close on EVERY exit path, not just success — a throw from
        // writeLine/runAllRecords below previously leaked the handle open.
        // `handleClosed` avoids a double-close: the success path below still
        // does its own `try handle.close()` (so a close() failure there is
        // reported, not swallowed — P1 review finding), and this defer only
        // does a best-effort `try?` close for the early-exit/error path,
        // where the ORIGINAL thrown error must propagate unmasked.
        var handleClosed = false
        defer {
            if !handleClosed {
                try? handle.close()
            }
        }
        let encoder = JSONEncoder()
        func writeLine<T: Encodable>(_ value: T) throws {
            var data = try encoder.encode(value)
            data.append(Data("\n".utf8))
            handle.write(data)
        }

        let buildConfig = env["VOICETYPE_REPLAY_BUILD_CONFIG"] ?? "debug"
        try writeLine(ReplayRunHeader(
            startedAt: ISO8601DateFormatter().string(from: Date()),
            mode: input.mode,
            input: input.inputDescription,
            model: modelURL.lastPathComponent,
            coreMLRequested: coreMLRequested,
            threads: Int(Self.recommendedThreadCount()),
            language: settings.language.rawValue,
            pipelineStamp: runPipelineStamp,
            promptHash: runStampParts.promptHashHex,
            promptSource: settings.promptSource,
            swiftWhisperRevision: swiftWhisperRevision,
            buildConfig: buildConfig,
            loadMs: loadMs
        ))

        let counts = try await Self.runAllRecords(
            records: input.records, context: context, writeLine: { try writeLine($0) }
        )

        let sortedMs = counts.transcribeMsSamples.sorted()
        try writeLine(ReplaySummaryJSON(
            records: input.records.count,
            errors: counts.errorCount,
            transcribeP50Ms: Self.percentile(sortedMs, 50),
            transcribeP95Ms: Self.percentile(sortedMs, 95),
            totalAudioSeconds: counts.totalAudioSeconds,
            totalTranscribeMs: counts.totalTranscribeMs,
            silenceGated: counts.silenceGatedCount
        ))

        try handle.close()
        handleClosed = true
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: outURL.path)

        if counts.errorCount > 0 {
            throw ReplayHarnessFailure(
                message: "\(counts.errorCount) of \(input.records.count) record(s) failed — see \(outURL.path)"
            )
        }
    }

    // MARK: - Phase 1: input resolution

    private static func resolveReplayInput(env: [String: String]) throws -> ResolvedReplayInput {
        let historyPath = env["VOICETYPE_REPLAY_HISTORY"]
        let dirPath = env["VOICETYPE_REPLAY_DIR"]
        guard (historyPath != nil) != (dirPath != nil) else {
            throw ReplayHarnessFailure(
                message: "Exactly one of VOICETYPE_REPLAY_HISTORY / VOICETYPE_REPLAY_DIR must be set"
            )
        }
        let limit = env["VOICETYPE_REPLAY_LIMIT"].flatMap(Int.init)

        let mode: String
        let inputDescription: String
        var records: [ReplayInput.Record]
        if let historyPath {
            let historyURL = URL(fileURLWithPath: historyPath)
            let audioDirectory = env["VOICETYPE_REPLAY_AUDIO_DIR"].map(URL.init(fileURLWithPath:))
                ?? historyURL.deletingLastPathComponent().appendingPathComponent("audio")
            records = try ReplayInput.resolveHistory(
                historyURL: historyURL,
                audioDirectory: audioDirectory,
                onlySaved: env["VOICETYPE_REPLAY_ONLY"] == "saved",
                limit: limit
            )
            mode = "history"
            inputDescription = historyPath
        } else {
            let dirURL = URL(fileURLWithPath: dirPath ?? "")
            records = try ReplayInput.resolveDirectory(dirURL)
            if let limit {
                records = Array(records.prefix(limit))
            }
            mode = "dir"
            inputDescription = dirPath ?? ""
        }

        guard !records.isEmpty else {
            throw ReplayHarnessFailure(
                message: "Zero records selected for replay (empty corpus, or --only-saved with nothing saved)"
            )
        }
        if let expect = env["VOICETYPE_REPLAY_EXPECT"].flatMap(Int.init) {
            guard records.count == expect else {
                throw ReplayHarnessFailure(
                    message: "VOICETYPE_REPLAY_EXPECT=\(expect) but resolved \(records.count) record(s)"
                )
            }
        }
        return ResolvedReplayInput(mode: mode, inputDescription: inputDescription, records: records)
    }

    private static func resolveOutputURLOrFail(_ outPath: String) throws -> URL {
        do {
            return try resolveOutputURL(outPath)
        } catch {
            throw ReplayHarnessFailure(message: "\(error)")
        }
    }

    // MARK: - Phase 2: settings — read com.voicetype.app raw, apply to AppSettings.shared

    private static func resolveEffectiveSettings(env: [String: String]) throws -> EffectiveSettings {
        guard let appDomain = UserDefaults(suiteName: "com.voicetype.app") else {
            throw ReplayHarnessFailure(message: "Could not open the com.voicetype.app UserDefaults domain (read-only)")
        }

        let rawLanguage = appDomain.string(forKey: "language") ?? Language.bilingualRuEn.rawValue
        let language = Language(rawValue: rawLanguage) ?? .bilingualRuEn
        let rawVocabulary = appDomain.string(forKey: "customVocabulary") ?? ""
        let normalize = appDomain.object(forKey: "normalizeTranscript") as? Bool ?? true
        let removeFillers = appDomain.object(forKey: "removeFillerWords") as? Bool ?? false
        let trim = appDomain.object(forKey: "trimWhitespaceAfterInsert") as? Bool ?? true
        let coreMLMode = CoreMLMode(rawValue: appDomain.string(forKey: "coreMLMode") ?? "") ?? .auto
        let storedModelRaw = appDomain.string(forKey: "selectedModel")
        let selectedModel = storedModelRaw.flatMap(TranscriptionModel.init(rawValue:))
            ?? TranscriptionModel.freshInstallDefault

        var promptSource = "app-domain"
        var effectiveVocabulary = rawVocabulary
        if let promptFilePath = env["VOICETYPE_REPLAY_PROMPT_FILE"] {
            guard let fileContents = try? String(contentsOfFile: promptFilePath, encoding: .utf8) else {
                throw ReplayHarnessFailure(
                    message: "VOICETYPE_REPLAY_PROMPT_FILE set but could not be read: \(promptFilePath)"
                )
            }
            effectiveVocabulary = fileContents
            promptSource = "file"
        } else if rawVocabulary.isEmpty {
            throw ReplayHarnessFailure(
                message: "customVocabulary is empty in com.voicetype.app and VOICETYPE_REPLAY_PROMPT_FILE is not "
                    + "set — prompt not read. A run with no prompt is only reachable via an explicit (possibly "
                    + "empty) VOICETYPE_REPLAY_PROMPT_FILE."
            )
        }

        return EffectiveSettings(
            language: language,
            vocabulary: effectiveVocabulary,
            normalize: normalize,
            removeFillers: removeFillers,
            trim: trim,
            coreMLMode: coreMLMode,
            selectedModel: selectedModel,
            promptSource: promptSource
        )
    }

    private static func apply(_ settings: EffectiveSettings) {
        AppSettings.shared.language = settings.language
        AppSettings.shared.customVocabulary = settings.vocabulary
        AppSettings.shared.normalizeTranscript = settings.normalize
        AppSettings.shared.removeFillerWords = settings.removeFillers
        AppSettings.shared.trimWhitespaceAfterInsert = settings.trim
        AppSettings.shared.selectedModel = settings.selectedModel
        AppSettings.shared.coreMLMode = settings.coreMLMode
    }

    private static func restore(_ original: OriginalSettings) {
        AppSettings.shared.language = original.language
        AppSettings.shared.customVocabulary = original.vocabulary
        AppSettings.shared.normalizeTranscript = original.normalize
        AppSettings.shared.removeFillerWords = original.removeFillers
        AppSettings.shared.trimWhitespaceAfterInsert = original.trim
        AppSettings.shared.selectedModel = original.selectedModel
        AppSettings.shared.coreMLMode = original.coreMLMode
    }

    // MARK: - Phase 3: model load

    private static func resolveModelURL(
        env: [String: String], selectedModel: TranscriptionModel
    ) throws -> (URL, TranscriptionModel?) {
        let modelURL: URL
        let modelForCoreML: TranscriptionModel?
        if let modelOverridePath = env["VOICETYPE_REPLAY_MODEL"] {
            modelURL = URL(fileURLWithPath: modelOverridePath)
            // An arbitrary override path carries no TranscriptionModel case, so
            // CoreML resolution reports metalOnly for it (hasCoreMLSupport
            // unknown ⇒ treated as false) — a manual debug lever, not the
            // primary R1 corpus run.
            modelForCoreML = nil
        } else {
            modelURL = ModelManager.shared.modelURL(for: selectedModel)
            modelForCoreML = selectedModel
        }
        guard FileManager.default.fileExists(atPath: modelURL.path) else {
            throw ReplayHarnessFailure(message: "Model file not found: \(modelURL.path)")
        }
        return (modelURL, modelForCoreML)
    }

    private static func waitUntilReady(_ service: TranscriptionService) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(120))
        while service.modelStatus != .ready {
            if case .error(let message) = service.modelStatus {
                throw ReplayHarnessFailure(message: "Model load error: \(message)")
            }
            guard ContinuousClock.now < deadline else {
                throw ReplayHarnessFailure(message: "Timed out waiting 120s for modelStatus == .ready")
            }
            try? await Task.sleep(for: .milliseconds(50))
        }
    }

    /// Fail-closed: refuses to run a single record unless the loaded model's
    /// actual prompt/name match what this run asked for.
    private static func verifyEffectiveConfiguration(
        service: TranscriptionService,
        settings: EffectiveSettings,
        modelURL: URL
    ) throws -> (String, StampParts) {
        let expectedSeed = settings.language.usesBilingualPrompt ? TranscriptionService.bilingualSeed : ""
        let expectedPromptRaw = PromptBudget.fullPrompt(seed: expectedSeed, vocabulary: settings.vocabulary)
        let expectedPrompt = expectedPromptRaw.isEmpty ? nil : expectedPromptRaw
        guard service.currentInitialPromptText == expectedPrompt else {
            throw ReplayHarnessFailure(
                message: "Effective prompt does not match expected configuration — refusing to run. "
                    + "expected=\(String(describing: expectedPrompt)) "
                    + "actual=\(String(describing: service.currentInitialPromptText))"
            )
        }
        guard service.loadedModelName == modelRawValue(fromFileName: modelURL.lastPathComponent) else {
            throw ReplayHarnessFailure(message: "Loaded model name does not match the requested model — refusing to run")
        }

        let stamp = TranscriptionService.pipelineStamp(
            forPrompt: service.currentInitialPromptText,
            normalizing: settings.normalize,
            removingFillers: settings.removeFillers
        )
        guard let parts = parseStamp(stamp) else {
            throw ReplayHarnessFailure(message: "Could not parse this run's own pipeline stamp: \(stamp)")
        }
        return (stamp, parts)
    }

    /// Mirrors TranscriptionService.loadModel's own AccelerationPolicyResolver
    /// inputs — computed here rather than exposed by production code (K1's
    /// only sanctioned production change is TimedSegment/segments).
    private static func computeCoreMLRequested(
        modelForCoreML: TranscriptionModel?, coreMLMode: CoreMLMode
    ) async -> Bool {
        let capability = await AcceleratorCapabilityProvider.shared.current()
        let hasCoreMLFile = modelForCoreML.map {
            FileManager.default.fileExists(atPath: ModelManager.shared.coreMLModelURL(for: $0).path)
        } ?? false
        let modelSupportsCoreML = modelForCoreML?.hasCoreMLSupport ?? false
        let coreMLInstalledForPolicy = modelSupportsCoreML && hasCoreMLFile
        let decision = AccelerationPolicyResolver.resolve(
            mode: coreMLMode, capability: capability, coreMLInstalled: coreMLInstalledForPolicy
        )
        return decision.policy == .coreML
    }

    // MARK: - Phase 4: output file

    private static func openOutputFile(_ url: URL) throws -> FileHandle {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        guard FileManager.default.createFile(atPath: url.path, contents: nil, attributes: [.posixPermissions: 0o600]) else {
            throw ReplayHarnessFailure(message: "Could not create output file at \(url.path)")
        }
        guard let handle = FileHandle(forWritingAtPath: url.path) else {
            throw ReplayHarnessFailure(message: "Could not open output file for writing at \(url.path)")
        }
        return handle
    }

    // MARK: - Phase 5: transcribe every record

    private static func runAllRecords(
        records: [ReplayInput.Record],
        context: RunContext,
        writeLine: (ReplayRecordJSON) throws -> Void
    ) async throws -> ReplaySummaryCounts {
        var transcribeMsSamples: [Int] = []
        var totalAudioSeconds = 0.0
        var totalTranscribeMs = 0
        var errorCount = 0
        var silenceGatedCount = 0

        for record in records {
            let outcome = await transcribeOne(record: record, context: context)
            try writeLine(outcome.json)
            if outcome.isError {
                errorCount += 1
            }
            if outcome.silenceGated {
                silenceGatedCount += 1
            }
            // totalAudioSeconds counts every successfully-read recording,
            // gated or not (it's a duration aggregate, not a work aggregate).
            if let seconds = outcome.audioSeconds {
                totalAudioSeconds += seconds
            }
            // transcribeMsSamples/totalTranscribeMs (and the P50/P95/RTF
            // derived from them) count only records where whisper actually
            // ran — transcribeMs is nil for both errors and gated records.
            if let ms = outcome.transcribeMs {
                transcribeMsSamples.append(ms)
                totalTranscribeMs += ms
            }
        }

        return ReplaySummaryCounts(
            errorCount: errorCount,
            silenceGatedCount: silenceGatedCount,
            transcribeMsSamples: transcribeMsSamples,
            totalAudioSeconds: totalAudioSeconds,
            totalTranscribeMs: totalTranscribeMs
        )
    }

    // computeComparability/transcribeOne moved to ReplayHarnessTests+Support.swift
    // purely for the 600-line file_length warning threshold (same reason as the
    // rest of that file's split — docs/plans/silence-gate.md T3 pushed this file
    // over budget).
}
