import XCTest
@testable import VoiceType

// Pure static helpers for ReplayHarnessTests.swift — split out purely for the
// 600-line file_length warning threshold, same reason TranscriptionService
// gained +PostProcess.swift. None of this touches AppSettings/TranscriptionService
// state; it's string/path/number math the driver calls into.
extension ReplayHarnessTests {

    /// Wraps every pre-flight/fail-closed refusal with a readable message.
    /// `testReplay()` catches every error uniformly and reports it via
    /// `XCTFail`, so a thrown `ReplayHarnessFailure` and a thrown production
    /// error (e.g. `TranscriptionError`) both surface the same way.
    struct ReplayHarnessFailure: Error, CustomStringConvertible {
        let message: String
        var description: String { message }
    }

    struct ResolvedReplayInput {
        let mode: String
        let inputDescription: String
        let records: [ReplayInput.Record]
    }

    struct EffectiveSettings {
        let language: Language
        let vocabulary: String
        let normalize: Bool
        let removeFillers: Bool
        let trim: Bool
        let coreMLMode: CoreMLMode
        let selectedModel: TranscriptionModel
        let promptSource: String
    }

    struct OriginalSettings {
        let language: Language
        let vocabulary: String
        let normalize: Bool
        let removeFillers: Bool
        let trim: Bool
        let selectedModel: TranscriptionModel
        let coreMLMode: CoreMLMode
    }

    struct RecordOutcome {
        let json: ReplayRecordJSON
        let isError: Bool
        let transcribeMs: Int?
        let audioSeconds: Double?
    }

    struct Comparability {
        let matches: Bool?
        let comparable: Bool?
    }

    struct ReplaySummaryCounts {
        let errorCount: Int
        let transcribeMsSamples: [Int]
        let totalAudioSeconds: Double
        let totalTranscribeMs: Int
    }

    /// Bundles the per-run constants every record needs, purely to keep
    /// transcribeOne/computeComparability/runAllRecords under swiftlint's
    /// function_parameter_count (5).
    struct RunContext {
        let mode: String
        let service: TranscriptionService
        let language: Language
        let runStampParts: StampParts
        let runModelRawValue: String
    }

    /// Duplicates `TranscriptionService.recommendedThreadCount` (private,
    /// production) rather than exposing a new test seam — quality-tools plan's
    /// only sanctioned production change is K1 (TimedSegment/segments). Pure
    /// function of `ProcessInfo`, so drift risk is "the algorithm changed",
    /// not "the environment changed" — see that property's formula.
    static func recommendedThreadCount() -> Int32 {
        let availableCores = max(1, ProcessInfo.processInfo.activeProcessorCount)
        let tunedCores = availableCores <= 4 ? availableCores : min(8, max(4, availableCores - 2))
        return Int32(tunedCores)
    }

    static func durationMs(from start: ContinuousClock.Instant, to end: ContinuousClock.Instant) -> Int {
        let (seconds, attoseconds) = (end - start).components
        return Int(seconds * 1_000 + attoseconds / 1_000_000_000_000_000)
    }

    /// Same string TranscriptionService.loadModel derives as `currentModelName`
    /// from a `.bin` filename ("ggml-<rawValue>.bin" → "<rawValue>").
    static func modelRawValue(fromFileName fileName: String) -> String {
        fileName.replacingOccurrences(of: "ggml-", with: "").replacingOccurrences(of: ".bin", with: "")
    }

    static func percentile(_ sortedValues: [Int], _ pct: Double) -> Int {
        guard !sortedValues.isEmpty else { return 0 }
        let idx = max(0, min(sortedValues.count - 1, Int((pct / 100.0 * Double(sortedValues.count - 1)).rounded())))
        return sortedValues[idx]
    }

    static func historySnapshot(for entry: HistoryStore.Entry?) -> ReplayHistorySnapshot? {
        guard let entry else { return nil }
        return ReplayHistorySnapshot(
            raw: entry.rawText ?? entry.text,
            text: entry.text,
            pipelineStamp: entry.pipelineStamp,
            model: entry.model,
            asrMs: entry.latencyMs?["asr"],
            status: entry.status?.rawValue
        )
    }

    /// Reads the SwiftWhisper pin's revision out of Package.resolved, at the
    /// repository root discovered via `repositoryRoot()`. Tolerates both the
    /// v1 (`object.pins`) and v2 (`pins`) SwiftPM lockfile schemas.
    static func swiftWhisperRevision() -> String? {
        let url = repositoryRoot().appendingPathComponent("Package.resolved")
        guard let data = try? Data(contentsOf: url),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        let pins: [[String: Any]]
        if let direct = root["pins"] as? [[String: Any]] {
            pins = direct
        } else if let object = root["object"] as? [String: Any], let nested = object["pins"] as? [[String: Any]] {
            pins = nested
        } else {
            pins = []
        }
        for pin in pins {
            let identity = (pin["identity"] as? String) ?? (pin["package"] as? String) ?? ""
            guard identity.lowercased() == "swiftwhisper" else { continue }
            if let state = pin["state"] as? [String: Any], let revision = state["revision"] as? String {
                return revision
            }
        }
        return nil
    }

    /// Walks up from this test file's own path to the nearest ancestor
    /// containing `.git` (a directory in the main checkout, a file in a
    /// worktree — `fileExists` doesn't distinguish, which is exactly what's
    /// needed here).
    static func repositoryRoot() -> URL {
        var dir = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        while !FileManager.default.fileExists(atPath: dir.appendingPathComponent(".git").path) {
            let parent = dir.deletingLastPathComponent()
            guard parent.path != dir.path else { break }
            dir = parent
        }
        return dir.standardizedFileURL.resolvingSymlinksInPath()
    }

    enum OutputPathError: Error, CustomStringConvertible {
        case insideRepository(String)
        var description: String {
            switch self {
            case .insideRepository(let path):
                return "Refusing to write replay output inside the repository (speech transcripts, public repo): \(path)"
            }
        }
    }

    /// Canonicalizes `rawPath` and rejects it if it resolves inside this
    /// checkout's working tree — same policy as scripts/history-report.py's
    /// `inside_repository`, enforced here because the harness, not just the
    /// wrapper script, must refuse to write transcripts into a public repo.
    static func resolveOutputURL(_ rawPath: String) throws -> URL {
        let expanded = (rawPath as NSString).expandingTildeInPath
        let url = URL(fileURLWithPath: expanded).standardizedFileURL
        // The file need not exist yet; resolve symlinks on the deepest
        // existing ancestor so a symlinked scratch directory still
        // canonicalizes correctly, then re-append the remaining components.
        var existingAncestor = url
        var remainder: [String] = []
        while !FileManager.default.fileExists(atPath: existingAncestor.path) {
            remainder.insert(existingAncestor.lastPathComponent, at: 0)
            let parent = existingAncestor.deletingLastPathComponent()
            guard parent.path != existingAncestor.path else { break }
            existingAncestor = parent
        }
        var canonical = existingAncestor.resolvingSymlinksInPath()
        for component in remainder {
            canonical = canonical.appendingPathComponent(component)
        }

        let repoRoot = repositoryRoot()
        if canonical.path == repoRoot.path || canonical.path.hasPrefix(repoRoot.path + "/") {
            throw OutputPathError.insideRepository(canonical.path)
        }
        return canonical
    }
}

struct StampParts: Equatable {
    let hasNoFill: Bool
    let hasNoLex: Bool
    let promptHashHex: String
}

/// Parses "n<version>[-nofill][-nolex]:p<hex>" — see
/// TranscriptionService.pipelineStamp(forPrompt:normalizing:removingFillers:).
func parseStamp(_ stamp: String) -> StampParts? {
    let parts = stamp.split(separator: ":", maxSplits: 1)
    guard parts.count == 2, parts[1].hasPrefix("p") else { return nil }
    let head = String(parts[0])
    let hex = String(parts[1].dropFirst())
    return StampParts(hasNoFill: head.contains("-nofill"), hasNoLex: head.contains("-nolex"), promptHashHex: hex)
}
