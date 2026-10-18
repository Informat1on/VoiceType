// HistoryStore.swift — VoiceType
//
// Append-only JSONL store for transcription history.
// File: ~/Library/Application Support/VoiceType/history.jsonl
// Rolling cap: 100 REGULAR entries (oldest evicted on insert). Saved eval
// pairs (isSavedEval == true) are exempt — see evictExcessRegularEntries().
// In-memory cache + atomic flush-on-write (re-writes whole file each time;
// grows unbounded with saved eval pairs — accepted cost, task 2 fix).
//
// Eval Collector (2026-04-27): audioPath/userCorrection/isSavedEval/model/
// audioDurationSeconds fields, all optional for backward compat. Audio files
// live in .../VoiceType/audio/<uuid>.caf; up to 100 unsaved kept, saved eval
// pairs forever.
//
// insertSuccess (task 1 fix): the entry is written BEFORE injectText runs and
// then updated with the actual outcome, so a failed insert never loses the
// transcript.
//
// rawText + pipelineStamp (2026-07-27): rawText is whisper's untouched output
// (nil when it equals `text`, to avoid doubling file size), pipelineStamp
// names the post-processing pipeline that produced `text`. Both nil on legacy
// entries. Consumers read `rawText ?? text`.
//
// DESIGN.md § Transcription History. Step 9.

import Foundation

// swiftlint:disable force_unwrapping

// D4/D6 (reliable-dictation): TranscriptionStatus, maxFailedEntries,
// evictExcessFailedEntries, promoteRetried and Entry's failed-transcription
// with…-helpers live in HistoryStore+FailedTranscriptions.swift, kept
// separate to stay under this file's line budget. A few members below are
// `internal` rather than `private` solely so that file can reach them.

/// Append-only JSONL store for transcription history.
/// File: ~/Library/Application Support/VoiceType/history.jsonl
/// Rolling cap: 100 regular entries (oldest evicted on insert); saved eval
/// pairs are exempt and kept forever. Failed entries (status == .failed) have
/// their own separate cap — see maxFailedEntries.
@MainActor
final class HistoryStore {

    // MARK: - Shared

    static let shared = HistoryStore(errorLogger: .shared)

    // MARK: - Entry

    struct Entry: Codable, Identifiable, Equatable {
        let id: UUID
        let timestamp: Date
        let text: String
        let charCount: Int
        let targetAppName: String        // "Cursor", "Safari", etc.
        let targetAppBundleID: String?   // "com.cursor.cursor" — nil if unknown
        let language: String             // "ru", "en", "ru+en", etc.

        // MARK: Eval Collector fields (all optional — old entries parse as nil)

        /// Filename relative to the audio directory (e.g. "abc123.caf").
        /// nil if no audio was captured or file was rotated away.
        let audioPath: String?

        /// User-supplied correction of the whisper output. nil if not yet edited.
        let userCorrection: String?

        /// true when the user clicked Save in EvalEditorWindow.
        /// Saved eval pairs are never subject to audio rotation.
        let isSavedEval: Bool?

        /// Eval Collector: what went wrong, set by the user when saving a corrected
        /// pair — "asr" | "postprocess" | "insertion" | "capture". nil = not set, or a
        /// control example saved as correct. Legacy entries decode as nil.
        let evalIssue: String?

        /// Transcription model used (e.g. "small.en-q5_1"). nil for legacy entries.
        let model: String?

        /// Duration of the audio recording in seconds. nil if not captured.
        let audioDurationSeconds: Double?

        /// Whether text injection actually succeeded. nil for legacy entries
        /// and briefly nil for the "pending" record written before injectText
        /// runs — see HistoryRecorder.recordOutcome(id:insertSuccess:).
        let insertSuccess: Bool?

        // MARK: Pre-normalizer fields (added ahead of the text normalizer landing)

        /// Untouched whisper output, before conditionallyTrim. nil means
        /// "identical to `text`" (legacy entries, or a no-op trim) — kept nil
        /// when equal so history.jsonl doesn't double in size. Consumers read
        /// `entry.rawText ?? entry.text`.
        let rawText: String?

        /// Snapshot of the pipeline that produced `text` — see
        /// TranscriptionService.pipelineStamp(forPrompt:). nil for legacy entries.
        let pipelineStamp: String?

        // MARK: D4/D6 fields (reliable-dictation plan, task C)

        /// nil for a regular entry (incl. every legacy entry). `.failed` = ASR
        /// error/timeout: text empty, audio kept, retryable from History.
        let status: TranscriptionStatus?

        /// "timeout" | "error" | "empty". nil for regular entries.
        let failureReason: String?

        /// Per-stage dictation latency in ms (D6), e.g. "asr"/"insert"/"total".
        /// nil when not measured.
        let latencyMs: [String: Int]?

        // isFailed + failed-transcription with…-helpers: see
        // HistoryStore+FailedTranscriptions.swift.

        // MARK: Primary init (used by AppDelegate transcription pipeline)

        init(
            text: String,
            targetAppName: String,
            targetAppBundleID: String?,
            language: String,
            audioPath: String? = nil,
            model: String? = nil,
            audioDurationSeconds: Double? = nil,
            insertSuccess: Bool? = nil,
            rawText: String? = nil,
            pipelineStamp: String? = nil,
            status: TranscriptionStatus? = nil,
            failureReason: String? = nil,
            latencyMs: [String: Int]? = nil
        ) {
            self.id = UUID()
            self.timestamp = Date()
            self.text = text
            self.charCount = text.count
            self.targetAppName = targetAppName
            self.targetAppBundleID = targetAppBundleID
            self.language = language
            self.audioPath = audioPath
            self.userCorrection = nil
            self.isSavedEval = nil
            self.evalIssue = nil
            self.model = model
            self.audioDurationSeconds = audioDurationSeconds
            self.insertSuccess = insertSuccess
            // Collapse to nil whenever the raw text matches the final text —
            // see the field's doc comment for why (avoids doubling file size).
            self.rawText = (rawText == text) ? nil : rawText
            self.pipelineStamp = pipelineStamp
            self.status = status
            self.failureReason = failureReason
            self.latencyMs = latencyMs
        }

        // MARK: Mutation helpers (produces a new value; Entry is a struct)
        //
        // withEvalSaved/withAudioPathCleared/withInsertOutcome: see
        // HistoryStore+EntryMutations.swift. withTranscriptionResult/
        // withLatency/withFailureReason: see
        // HistoryStore+FailedTranscriptions.swift. All call this full
        // memberwise init below, hence `internal` rather than `private`.
        init(
            id: UUID,
            timestamp: Date,
            text: String,
            charCount: Int,
            targetAppName: String,
            targetAppBundleID: String?,
            language: String,
            audioPath: String?,
            userCorrection: String?,
            isSavedEval: Bool?,
            evalIssue: String?,
            model: String?,
            audioDurationSeconds: Double?,
            insertSuccess: Bool?,
            rawText: String?,
            pipelineStamp: String?,
            status: TranscriptionStatus?,
            failureReason: String?,
            latencyMs: [String: Int]?
        ) {
            self.id = id
            self.timestamp = timestamp
            self.text = text
            self.charCount = charCount
            self.targetAppName = targetAppName
            self.targetAppBundleID = targetAppBundleID
            self.language = language
            self.audioPath = audioPath
            self.userCorrection = userCorrection
            self.isSavedEval = isSavedEval
            self.evalIssue = evalIssue
            self.model = model
            self.audioDurationSeconds = audioDurationSeconds
            self.insertSuccess = insertSuccess
            // Already normalized by the primary init — carry over as-is.
            self.rawText = rawText
            self.pipelineStamp = pipelineStamp
            self.status = status
            self.failureReason = failureReason
            self.latencyMs = latencyMs
        }
    }

    // MARK: - Private state

    private let storeURL: URL
    /// Directory where audio recordings are stored. Defaults to
    /// ~/Library/Application Support/VoiceType/audio/
    let audioDirectory: URL
    /// Error sink for this store's own failures (disk-full, corrupt file,
    /// dropped audio deletions). Production uses `.shared`; tests inject
    /// `ErrorLogger.test(logsDirectory:)` via `HistoryStore.test(...)` so
    /// their errors never reach the real errors.log (T3, plan §3).
    private let errorLogger: ErrorLogger
    /// Cap on REGULAR (non-eval, non-failed) entries only — see
    /// evictExcessRegularEntries().
    private let maxEntries: Int = 100
    /// Maximum number of unsaved audio files to keep in rolling buffer.
    private let maxUnsavedAudio: Int = 100
    // maxFailedEntries: see HistoryStore+FailedTranscriptions.swift.
    /// Upper bound on the deferred-deletion queue, so a persistently failing
    /// disk cannot grow it without limit. Generous on purpose: reaching it
    /// means writes have failed thousands of times in a row.
    private let maxPendingAudioDeletions: Int = 1000
    private let fileManager = FileManager.default
    /// Newest-first ordering in memory. `internal` (not `private`) for
    /// HistoryStore+FailedTranscriptions.swift.
    var cachedEntries: [Entry] = []
    private var loaded: Bool = false
    /// Audio files whose owning entries are already gone from the cache but whose
    /// removal is still unsafe, because the JSONL that stops referencing them has
    /// not been written yet. Accumulates across failed flushes: a per-call list
    /// would be lost on the failing call, and the next successful flush would
    /// delete only its own files, orphaning the earlier ones forever.
    /// Review finding, wave A re-review. `internal` for the same reason as
    /// cachedEntries above.
    var pendingAudioDeletions: [String] = []
    /// True when the history file existed but could not be read on first load.
    /// Blocks flush() from overwriting a file we couldn't parse.
    private var loadFailed: Bool = false

    // MARK: - Init

    private init(storeURL: URL? = nil, audioDirectory: URL? = nil, errorLogger: ErrorLogger) {
        self.errorLogger = errorLogger
        if let custom = storeURL {
            self.storeURL = custom
            self.audioDirectory = audioDirectory
                ?? custom.deletingLastPathComponent().appendingPathComponent("audio")
        } else {
            let appSupport = FileManager.default.urls(
                for: .applicationSupportDirectory,
                in: .userDomainMask
            ).first!
            let voiceTypeDir = appSupport.appendingPathComponent("VoiceType")
            try? FileManager.default.createDirectory(at: voiceTypeDir, withIntermediateDirectories: true)
            self.storeURL = voiceTypeDir.appendingPathComponent("history.jsonl")
            self.audioDirectory = audioDirectory
                ?? voiceTypeDir.appendingPathComponent("audio")
            // Eager only on the production path — test paths create it on
            // demand (some disk-full tests deliberately omit the parent dir).
            try? FileManager.default.createDirectory(
                at: self.audioDirectory, withIntermediateDirectories: true)
        }
    }

    /// Ensure the audio directory exists. Called lazily before first audio access.
    func ensureAudioDirectoryExists() {
        try? fileManager.createDirectory(at: audioDirectory, withIntermediateDirectories: true)
    }

    /// Test seam — pass a temp-dir URL and a temp-dir `ErrorLogger` so tests
    /// are fully hermetic (neither touches the real ~/Library paths).
    /// `errorLogger` has no default on purpose — every call site in Tests/
    /// must pass its own `ErrorLogger.test(logsDirectory:)` rather than
    /// silently falling back to `.shared` (T3, plan §3).
    static func test(storeURL: URL, audioDirectory: URL? = nil, errorLogger: ErrorLogger) -> HistoryStore {
        HistoryStore(storeURL: storeURL, audioDirectory: audioDirectory, errorLogger: errorLogger)
    }

    // MARK: - Public API

    /// Append a new entry. Evicts oldest REGULAR entries when the cap is exceeded
    /// (saved eval pairs are exempt — see evictExcessRegularEntries()). Flushes to disk.
    /// After appending, rotates audio files if the unsaved-audio buffer exceeds 100.
    func append(_ entry: Entry) {
        loadIfNeeded()
        cachedEntries.insert(entry, at: 0)
        // Audio deletion is deferred until the new state is safely on disk —
        // a failed flush would otherwise leave the old JSONL pointing at
        // files we already removed. Review finding, wave A.
        pendingAudioDeletions += evictExcessRegularEntries() + rotateAudioIfNeeded() + evictExcessFailedEntries()
        flushAndReapAudio()
    }

    /// Writes the cache and, only on success, deletes every audio file queued
    /// so far. Failed flushes leave the queue intact for a later retry.
    ///
    /// EVERY successful write goes through here, not just append() — update(),
    /// delete() and clear() also persist the cache, and a queue drained only
    /// by append() could be stranded until the process exited (wave B).
    /// `internal` (not `private`) for HistoryStore+FailedTranscriptions.swift.
    func flushAndReapAudio() {
        guard flush() else {
            // A disk that stays broken would otherwise grow this queue by one
            // filename per eviction forever. Bound it: past the cap the oldest
            // names are dropped, which leaks those files on disk but keeps
            // memory finite. Leaking is the lesser failure, and reaching this
            // cap already means writes have been failing for a very long time.
            pendingAudioDeletions = capped(pendingAudioDeletions)
            return
        }
        // Files that could not be removed stay queued — dropping them here would
        // leak them silently, which is the very thing the queue exists to avoid.
        // The cap applies here too: a disk that writes JSONL fine but refuses
        // every audio deletion would otherwise grow the queue without bound
        // even though flush keeps succeeding. Review finding, wave B re-review.
        pendingAudioDeletions = capped(deleteAudioFiles(pendingAudioDeletions))
    }

    /// Trims the deferred-deletion queue to its cap, dropping the oldest names.
    /// Those files leak on disk, but an unbounded queue is the worse failure —
    /// and reaching the cap already means something has been wrong for a long time.
    private func capped(_ queue: [String]) -> [String] {
        guard queue.count > maxPendingAudioDeletions else { return queue }
        let overflow = queue.count - maxPendingAudioDeletions
        errorLogger.log(
            message: "HistoryStore: dropped \(overflow) queued audio deletions — the deferred-deletion queue hit its cap",
            category: "history"
        )
        return Array(queue.dropFirst(overflow))
    }

    /// All entries, newest first.
    func entries() -> [Entry] {
        loadIfNeeded()
        return cachedEntries
    }

    /// The most recent REGULAR entry (status == nil), or nil if there is none.
    /// Used by Cmd+Opt+E re-insert — a failed entry has no text to re-insert,
    /// so it must be skipped in favor of the newest entry that actually has one.
    func latestEntry() -> Entry? {
        loadIfNeeded()
        return cachedEntries.first { $0.status == nil }
    }

    /// Replace an existing entry by ID. No-op if the ID is not found. Flushes to disk.
    func update(_ updated: Entry) {
        loadIfNeeded()
        guard let idx = cachedEntries.firstIndex(where: { $0.id == updated.id }) else { return }
        cachedEntries[idx] = updated
        flushAndReapAudio()
    }

    // promoteRetried(_:) is declared in HistoryStore+FailedTranscriptions.swift.

    /// Delete a single entry by ID. Flushes to disk.
    func delete(_ id: UUID) {
        loadIfNeeded()
        cachedEntries.removeAll { $0.id == id }
        flushAndReapAudio()
    }

    /// Delete all entries and truncate the file.
    func clear() {
        cachedEntries.removeAll()
        flushAndReapAudio()
    }

    /// Count of entries where isSavedEval == true.
    func savedEvalCount() -> Int {
        loadIfNeeded()
        return cachedEntries.filter { $0.isSavedEval == true }.count
    }

    /// Look up a single entry by its UUID. Returns nil if the ID is not found.
    func entry(byID id: UUID) -> Entry? {
        loadIfNeeded()
        return cachedEntries.first { $0.id == id }
    }

    // MARK: - Rolling cap (entries)

    /// Evicts the oldest REGULAR entries once their count exceeds maxEntries,
    /// returning their audio filenames for deletion after a successful flush
    /// (an evicted entry is gone from the cache, so rotateAudioIfNeeded()
    /// would never see its audio again — leaving it unclaimed would orphan it).
    ///
    /// Saved eval pairs (isSavedEval == true) are exempt — "kept forever" per
    /// the file header — as an accepted cost (task 2): history.jsonl grows
    /// without bound as they accumulate. Track via savedEvalCount().
    ///
    /// Called from both append() and loadIfNeeded() so a restart re-applies
    /// the same rule. D4: a REGULAR entry is now `isSavedEval != true &&
    /// !isFailed` — see evictExcessFailedEntries() in
    /// HistoryStore+FailedTranscriptions.swift for the failed-entry cap.
    /// `internal` for that file's use.
    func evictExcessRegularEntries() -> [String] {
        let regularCount = cachedEntries.filter { $0.isSavedEval != true && !$0.isFailed }.count
        guard regularCount > maxEntries else { return [] }
        let excess = regularCount - maxEntries

        // Oldest-first among regular entries (cachedEntries itself is newest-first).
        let evicted = cachedEntries
            .filter { $0.isSavedEval != true && !$0.isFailed }
            .reversed()
            .prefix(excess)

        let orphanedAudio = evicted.compactMap(\.audioPath)
        let idSet = Set(evicted.map(\.id))
        cachedEntries.removeAll { idSet.contains($0.id) }
        return orphanedAudio
    }

    // evictExcessFailedEntries() is declared in
    // HistoryStore+FailedTranscriptions.swift.

    // MARK: - Audio rotation

    /// Rotate unsaved audio files: keeps up to maxUnsavedAudio. Saved eval
    /// pairs and failed entries (D4 — their audio is what a retry needs, and
    /// they have their own eviction path) are never rotated. Called
    /// automatically after every append().
    ///
    /// With maxUnsavedAudio == maxEntries this is currently unreachable for
    /// regular entries (evictExcessRegularEntries() caps them first); kept as
    /// the guard that holds if the two caps ever diverge.
    ///
    /// Returns the detached audio filenames, for deletion after a successful
    /// flush(). `internal` for HistoryStore+FailedTranscriptions.swift's use.
    func rotateAudioIfNeeded() -> [String] {
        // Collect unsaved, non-failed entries that have audio, oldest-first
        // (cachedEntries is newest-first).
        let unsavedWithAudio = cachedEntries
            .filter { $0.isSavedEval != true && !$0.isFailed && $0.audioPath != nil }
            .reversed() // oldest first

        guard unsavedWithAudio.count > maxUnsavedAudio else { return [] }

        let excess = unsavedWithAudio.count - maxUnsavedAudio
        let toEvict = unsavedWithAudio.prefix(excess)

        var detachedAudio: [String] = []
        for entry in toEvict {
            if let path = entry.audioPath {
                detachedAudio.append(path)
            }
            // Update entry in cache: clear audioPath.
            if let idx = cachedEntries.firstIndex(where: { $0.id == entry.id }) {
                cachedEntries[idx] = cachedEntries[idx].withAudioPathCleared()
            }
        }
        return detachedAudio
    }

    /// Removes audio files whose owning entries no longer reference them.
    /// Always called after a successful flush(), never before.
    /// Returns the ones that could not be removed, so they stay queued.
    ///
    /// `audioPath` normally holds only `<UUID>.caf` names the app itself
    /// wrote, but `history.jsonl` can be hand-edited or corrupted, and
    /// `appendingPathComponent` would happily follow a value like
    /// "../../something" outside `audioDirectory`. Anything that is not a
    /// plain base filename is rejected before it ever reaches the
    /// filesystem call: never deleted, and dropped from the queue rather
    /// than retried — the name itself is invalid, so there is nothing a
    /// retry could fix. Review finding r1, plan T3.
    private func deleteAudioFiles(_ filenames: [String]) -> [String] {
        var failed: [String] = []
        for filename in filenames {
            guard Self.isSafeAudioFilename(filename) else {
                errorLogger.log(
                    message: "HistoryStore: refused to delete a queued audio filename — not a plain base name",
                    category: "history"
                )
                continue
            }
            let url = audioDirectory.appendingPathComponent(filename)
            do {
                try fileManager.removeItem(at: url)
            } catch CocoaError.fileNoSuchFile {
                // Already gone — nothing to retry.
            } catch {
                failed.append(filename)
            }
        }
        return failed
    }

    /// True for a plain base filename: non-empty, no path separator, and
    /// not "." / ".." / hidden (the `hasPrefix(".")` check subsumes both
    /// dot-names). `internal` (not `private`) so a test could call it
    /// directly if needed; exercised via the black-box eviction test in
    /// HistoryStoreEdgeCasesTests (testDeleteAudioFilesRejectsPathTraversalNames).
    static func isSafeAudioFilename(_ filename: String) -> Bool {
        !filename.isEmpty && !filename.contains("/") && !filename.hasPrefix(".")
    }

    /// Deletes an audio file no History entry owns (empty-result path, docs/
    /// plans/empty-result-audio.md §3 C3) — immediate, not queued like
    /// `deleteAudioFiles`, since the file was never referenced. Safety, in
    /// order, each refusal logged WITHOUT the filename: (1) must pass
    /// `isSafeAudioFilename`; (2) must not be referenced by `audioPath` on any
    /// cached entry (after `loadIfNeeded()`); (3) otherwise `removeItem` — a
    /// missing file is silently ignored, any other error logged.
    func discardUnreferencedAudio(named filename: String) {
        guard Self.isSafeAudioFilename(filename) else {
            errorLogger.log(message: "HistoryStore: refused to discard audio — not a plain base filename", category: "history")
            return
        }

        loadIfNeeded()
        guard !cachedEntries.contains(where: { $0.audioPath == filename }) else {
            errorLogger.log(message: "HistoryStore: refused to discard audio still referenced by a History entry", category: "history")
            return
        }

        let url = audioDirectory.appendingPathComponent(filename)
        do {
            try fileManager.removeItem(at: url)
        } catch CocoaError.fileNoSuchFile {
            // Already gone — nothing to do.
        } catch {
            errorLogger.log(error, category: "history")
        }
    }

    // MARK: - Private helpers

    /// `internal` (not `private`) for HistoryStore+FailedTranscriptions.swift.
    func loadIfNeeded() {
        guard !loaded else { return }
        loaded = true
        guard fileManager.fileExists(atPath: storeURL.path),
              let data = try? Data(contentsOf: storeURL),
              let raw = String(data: data, encoding: .utf8) else {
            if fileManager.fileExists(atPath: storeURL.path) {
                loadFailed = true
                errorLogger.log(
                    message: "HistoryStore: history file exists but could not be read — writes disabled to protect data",
                    category: "history"
                )
            }
            return
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        var entries: [Entry] = []
        for line in raw.split(separator: "\n", omittingEmptySubsequences: true) {
            if let lineData = line.data(using: .utf8),
               let entry = try? decoder.decode(Entry.self, from: lineData) {
                entries.append(entry)
            }
        }
        // File is stored oldest-first; reverse for newest-first in-memory use.
        cachedEntries = entries.reversed()
        // Same rule as append() (task 2 fix + D4's separate failed-entry cap),
        // re-applied on load so a restart-only eviction still cleans up.
        let orphanedAudio = evictExcessRegularEntries() + evictExcessFailedEntries()
        if !orphanedAudio.isEmpty || cachedEntries.count != entries.count {
            pendingAudioDeletions += orphanedAudio
            flushAndReapAudio()
        }
    }

    /// Atomically rewrite the whole file in chronological (oldest-first) order.
    /// Returns false when the write failed or was refused, so callers can hold
    /// back destructive follow-up work (audio deletion).
    @discardableResult
    private func flush() -> Bool {
        guard !loadFailed else { return false }
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        // Persist chronologically so future appends are natural.
        let chronological = cachedEntries.reversed()
        var bytes = Data()
        for entry in chronological {
            if let data = try? encoder.encode(entry),
               let line = String(data: data, encoding: .utf8) {
                bytes.append(Data((line + "\n").utf8))
            }
        }
        let result = Result { try bytes.write(to: storeURL, options: .atomic) }
        if case .failure(let error) = result {
            errorLogger.log(error, category: "history", context: ["path": storeURL.path])
            return false
        }
        return true
    }
}

// swiftlint:enable force_unwrapping
