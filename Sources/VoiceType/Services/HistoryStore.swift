// HistoryStore.swift — VoiceType
//
// Append-only JSONL store for transcription history.
// File: ~/Library/Application Support/VoiceType/history.jsonl
// Rolling cap: 100 REGULAR entries (oldest evicted on insert). Saved eval
// pairs (isSavedEval == true) are exempt — see evictExcessRegularEntries().
// In-memory cache + atomic flush-on-write. Re-writes whole file each time
// (acceptable at regular-entry scale; grows unbounded with saved eval pairs
// — accepted cost, see evictExcessRegularEntries() doc comment, task 2 fix).
//
// Eval Collector extension (2026-04-27):
//   - Entry gains optional audioPath, userCorrection, isSavedEval, model,
//     audioDurationSeconds fields. All optional for backward compat.
//   - Audio files live in ~/Library/Application Support/VoiceType/audio/<uuid>.caf
//   - Rolling buffer: up to 100 unsaved audio files; saved eval pairs kept forever.
//
// insertSuccess field (task 1 fix, architectural audit): records whether
// injectText actually succeeded. Populated by HistoryRecorder after the
// entry is already persisted, so a failed insert never loses the transcript.
//
// DESIGN.md § Transcription History. Step 9.

import Foundation

// swiftlint:disable force_unwrapping

/// Append-only JSONL store for transcription history.
/// File: ~/Library/Application Support/VoiceType/history.jsonl
/// Rolling cap: 100 regular entries (oldest evicted on insert); saved eval
/// pairs are exempt and kept forever.
@MainActor
final class HistoryStore {

    // MARK: - Shared

    static let shared = HistoryStore()

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

        /// Transcription model used (e.g. "small.en-q5_1"). nil for legacy entries.
        let model: String?

        /// Duration of the audio recording in seconds. nil if not captured.
        let audioDurationSeconds: Double?

        /// Whether text injection actually succeeded. nil for legacy entries
        /// written before this field existed, and briefly nil for the
        /// "pending" record HistoryRecorder writes before injectText runs —
        /// see HistoryRecorder.recordOutcome(id:insertSuccess:).
        /// DESIGN.md § Transcription History specifies this field; audit
        /// finding (task 1, P1): the entry used to be written only on
        /// success, so a failed insert silently dropped the transcript.
        let insertSuccess: Bool?

        // MARK: Primary init (used by AppDelegate transcription pipeline)

        init(
            text: String,
            targetAppName: String,
            targetAppBundleID: String?,
            language: String,
            audioPath: String? = nil,
            model: String? = nil,
            audioDurationSeconds: Double? = nil,
            insertSuccess: Bool? = nil
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
            self.model = model
            self.audioDurationSeconds = audioDurationSeconds
            self.insertSuccess = insertSuccess
        }

        // MARK: Mutation helpers (produces a new value; Entry is a struct)

        /// Returns a copy with userCorrection and isSavedEval set.
        func withEvalSaved(correction: String) -> Entry {
            Entry(
                id: id,
                timestamp: timestamp,
                text: text,
                charCount: charCount,
                targetAppName: targetAppName,
                targetAppBundleID: targetAppBundleID,
                language: language,
                audioPath: audioPath,
                userCorrection: correction,
                isSavedEval: true,
                model: model,
                audioDurationSeconds: audioDurationSeconds,
                insertSuccess: insertSuccess
            )
        }

        /// Returns a copy with audioPath cleared (rotation).
        func withAudioPathCleared() -> Entry {
            Entry(
                id: id,
                timestamp: timestamp,
                text: text,
                charCount: charCount,
                targetAppName: targetAppName,
                targetAppBundleID: targetAppBundleID,
                language: language,
                audioPath: nil,
                userCorrection: userCorrection,
                isSavedEval: isSavedEval,
                model: model,
                audioDurationSeconds: audioDurationSeconds,
                insertSuccess: insertSuccess
            )
        }

        /// Returns a copy with insertSuccess set to the actual injection outcome.
        /// HistoryRecorder calls this after injectText returns — see task 1 (P1):
        /// the entry itself is written BEFORE injection is attempted (via the
        /// primary init above, insertSuccess left nil), so the transcript is
        /// never lost even if injection fails; this call just records the result.
        func withInsertOutcome(_ succeeded: Bool) -> Entry {
            Entry(
                id: id,
                timestamp: timestamp,
                text: text,
                charCount: charCount,
                targetAppName: targetAppName,
                targetAppBundleID: targetAppBundleID,
                language: language,
                audioPath: audioPath,
                userCorrection: userCorrection,
                isSavedEval: isSavedEval,
                model: model,
                audioDurationSeconds: audioDurationSeconds,
                insertSuccess: succeeded
            )
        }

        // Full memberwise init used by mutation helpers above.
        private init(
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
            model: String?,
            audioDurationSeconds: Double?,
            insertSuccess: Bool?
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
            self.model = model
            self.audioDurationSeconds = audioDurationSeconds
            self.insertSuccess = insertSuccess
        }
    }

    // MARK: - Private state

    private let storeURL: URL
    /// Directory where audio recordings are stored. Defaults to
    /// ~/Library/Application Support/VoiceType/audio/
    let audioDirectory: URL
    /// Cap on REGULAR (non-eval) entries only — see evictExcessRegularEntries().
    private let maxEntries: Int = 100
    /// Maximum number of unsaved audio files to keep in rolling buffer.
    private let maxUnsavedAudio: Int = 100
    private let fileManager = FileManager.default
    /// Newest-first ordering in memory.
    private var cachedEntries: [Entry] = []
    private var loaded: Bool = false
    /// True when the history file existed but could not be read on first load.
    /// Blocks flush() from overwriting a file we couldn't parse.
    private var loadFailed: Bool = false

    // MARK: - Init

    private init(storeURL: URL? = nil, audioDirectory: URL? = nil) {
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
            // Only create the audio directory eagerly for the production path.
            // Test paths create it on demand to avoid interfering with
            // disk-full edge-case tests that deliberately omit the parent dir.
            try? FileManager.default.createDirectory(
                at: self.audioDirectory, withIntermediateDirectories: true)
        }
    }

    /// Ensure the audio directory exists. Called lazily before first audio access.
    func ensureAudioDirectoryExists() {
        try? fileManager.createDirectory(at: audioDirectory, withIntermediateDirectories: true)
    }

    /// Test seam — pass a temp-dir URL so tests are hermetic.
    static func test(storeURL: URL, audioDirectory: URL? = nil) -> HistoryStore {
        HistoryStore(storeURL: storeURL, audioDirectory: audioDirectory)
    }

    // MARK: - Public API

    /// Append a new entry. Evicts oldest REGULAR entries when the cap is exceeded
    /// (saved eval pairs are exempt — see evictExcessRegularEntries()). Flushes to disk.
    /// After appending, rotates audio files if the unsaved-audio buffer exceeds 100.
    func append(_ entry: Entry) {
        loadIfNeeded()
        cachedEntries.insert(entry, at: 0)
        // Audio deletion is deferred until the new state is safely on disk:
        // if flush() fails (full disk, permissions), the old JSONL survives and
        // would otherwise point at files we had already removed. Leaking an
        // audio file on a crashed write is recoverable; a dangling reference
        // in a record the user can still see is not. Review finding, wave A.
        let orphanedAudio = evictExcessRegularEntries() + rotateAudioIfNeeded()
        if flush() {
            deleteAudioFiles(orphanedAudio)
        }
    }

    /// All entries, newest first.
    func entries() -> [Entry] {
        loadIfNeeded()
        return cachedEntries
    }

    /// The most recent entry, or nil if the store is empty.
    func latestEntry() -> Entry? {
        loadIfNeeded()
        return cachedEntries.first
    }

    /// Replace an existing entry by ID. No-op if the ID is not found. Flushes to disk.
    func update(_ updated: Entry) {
        loadIfNeeded()
        guard let idx = cachedEntries.firstIndex(where: { $0.id == updated.id }) else { return }
        cachedEntries[idx] = updated
        flush()
    }

    /// Delete a single entry by ID. Flushes to disk.
    func delete(_ id: UUID) {
        loadIfNeeded()
        cachedEntries.removeAll { $0.id == id }
        flush()
    }

    /// Delete all entries and truncate the file.
    func clear() {
        cachedEntries.removeAll()
        flush()
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

    /// Evicts the oldest REGULAR (non-eval) entries once their count exceeds
    /// maxEntries, deleting each evicted entry's audio file directly (it is
    /// gone from the cache entirely, so rotateAudioIfNeeded() will never see
    /// it again — leaving the file behind would orphan it on disk).
    ///
    /// Saved eval pairs (isSavedEval == true) are exempt from this cap — the
    /// file header promises "saved eval pairs kept forever". Cost accepted
    /// (review finding, task 2): history.jsonl, the saved audio files, and the
    /// full-file rewrite in flush() now grow without an upper bound as saved
    /// eval pairs accumulate, since nothing currently caps that count. Track
    /// via HistoryStore.savedEvalCount() if this needs revisiting.
    ///
    /// Called from both append() and loadIfNeeded() — the same rule must hold
    /// after a restart, otherwise entries saved before this fix (when the cap
    /// applied to the total regardless of isSavedEval) would be silently
    /// re-pruned on the next load.
    /// Returns the audio filenames belonging to evicted entries. The caller
    /// deletes them only after flush() succeeds — see append().
    private func evictExcessRegularEntries() -> [String] {
        let regularCount = cachedEntries.filter { $0.isSavedEval != true }.count
        guard regularCount > maxEntries else { return [] }
        let excess = regularCount - maxEntries

        // Oldest-first among regular entries (cachedEntries itself is newest-first).
        let evicted = cachedEntries
            .filter { $0.isSavedEval != true }
            .reversed()
            .prefix(excess)

        let orphanedAudio = evicted.compactMap(\.audioPath)
        let idSet = Set(evicted.map(\.id))
        cachedEntries.removeAll { idSet.contains($0.id) }
        return orphanedAudio
    }

    // MARK: - Audio rotation

    /// Rotate unsaved audio files: keeps up to maxUnsavedAudio.
    /// Saved eval pairs (isSavedEval == true) are never rotated.
    /// Called automatically after every append().
    ///
    /// Note that with maxUnsavedAudio == maxEntries this is currently
    /// unreachable for regular entries: evictExcessRegularEntries() caps them
    /// at maxEntries first, and entries carrying audio are a subset of those.
    /// It is kept as the guard that keeps holding if the two caps ever diverge
    /// (a smaller audio budget than entry budget is the plausible change).
    ///
    /// Returns the audio filenames it detached, for deletion after a successful
    /// flush() — same ordering rule as evictExcessRegularEntries().
    private func rotateAudioIfNeeded() -> [String] {
        // Collect unsaved entries that have audio, oldest-first (cachedEntries is newest-first).
        let unsavedWithAudio = cachedEntries
            .filter { $0.isSavedEval != true && $0.audioPath != nil }
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
    private func deleteAudioFiles(_ filenames: [String]) {
        for filename in filenames {
            try? fileManager.removeItem(at: audioDirectory.appendingPathComponent(filename))
        }
    }

    // MARK: - Private helpers

    private func loadIfNeeded() {
        guard !loaded else { return }
        loaded = true
        guard fileManager.fileExists(atPath: storeURL.path),
              let data = try? Data(contentsOf: storeURL),
              let raw = String(data: data, encoding: .utf8) else {
            if fileManager.fileExists(atPath: storeURL.path) {
                loadFailed = true
                ErrorLogger.shared.log(
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
        // File is stored oldest-first (chronological append order).
        // Reverse to get newest-first for in-memory usage.
        cachedEntries = entries.reversed()
        // Same rule as append(): cap applies only to regular entries, saved eval
        // pairs are exempt (task 2 fix). Re-flush if this actually trimmed
        // anything so the on-disk file matches — otherwise a restart-only
        // eviction would delete orphaned audio here but leave stale JSONL
        // lines on disk until the next append().
        let orphanedAudio = evictExcessRegularEntries()
        if !orphanedAudio.isEmpty || cachedEntries.count != entries.count {
            // Audio is deleted only once the trimmed file is safely written —
            // same ordering rule as append(), for the same reason.
            if flush() {
                deleteAudioFiles(orphanedAudio)
            }
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
            ErrorLogger.shared.log(error, category: "history", context: ["path": storeURL.path])
            return false
        }
        return true
    }
}

// swiftlint:enable force_unwrapping
