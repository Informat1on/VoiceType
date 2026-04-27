// HistoryStore.swift — VoiceType
//
// Append-only JSONL store for transcription history.
// File: ~/Library/Application Support/VoiceType/history.jsonl
// Rolling cap: 100 entries (oldest evicted on insert).
// In-memory cache + atomic flush-on-write. Re-writes whole file each time
// (acceptable: ≤100 entries, measured at ~40µs).
//
// Eval Collector extension (2026-04-27):
//   - Entry gains optional audioPath, userCorrection, isSavedEval, model,
//     audioDurationSeconds fields. All optional for backward compat.
//   - Audio files live in ~/Library/Application Support/VoiceType/audio/<uuid>.caf
//   - Rolling buffer: up to 100 unsaved audio files; saved eval pairs kept forever.
//
// DESIGN.md § Transcription History. Step 9.

import Foundation

// swiftlint:disable force_unwrapping

/// Append-only JSONL store for transcription history.
/// File: ~/Library/Application Support/VoiceType/history.jsonl
/// Rolling cap: 100 entries (oldest evicted on insert).
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

        // MARK: Primary init (used by AppDelegate transcription pipeline)

        init(
            text: String,
            targetAppName: String,
            targetAppBundleID: String?,
            language: String,
            audioPath: String? = nil,
            model: String? = nil,
            audioDurationSeconds: Double? = nil
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
                audioDurationSeconds: audioDurationSeconds
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
                audioDurationSeconds: audioDurationSeconds
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
            audioDurationSeconds: Double?
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
        }
    }

    // MARK: - Private state

    private let storeURL: URL
    /// Directory where audio recordings are stored. Defaults to
    /// ~/Library/Application Support/VoiceType/audio/
    let audioDirectory: URL
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

    /// Append a new entry. Evicts oldest when cap is exceeded. Flushes to disk.
    /// After appending, rotates audio files if the unsaved-audio buffer exceeds 100.
    func append(_ entry: Entry) {
        loadIfNeeded()
        cachedEntries.insert(entry, at: 0)
        if cachedEntries.count > maxEntries {
            cachedEntries.removeLast(cachedEntries.count - maxEntries)
        }
        rotateAudioIfNeeded()
        flush()
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

    // MARK: - Audio rotation

    /// Rotate unsaved audio files: keeps up to maxUnsavedAudio.
    /// Saved eval pairs (isSavedEval == true) are never rotated.
    /// Called automatically after every append().
    private func rotateAudioIfNeeded() {
        // Collect unsaved entries that have audio, oldest-first (cachedEntries is newest-first).
        let unsavedWithAudio = cachedEntries
            .filter { $0.isSavedEval != true && $0.audioPath != nil }
            .reversed() // oldest first

        guard unsavedWithAudio.count > maxUnsavedAudio else { return }

        let excess = unsavedWithAudio.count - maxUnsavedAudio
        let toEvict = unsavedWithAudio.prefix(excess)

        for entry in toEvict {
            // Delete audio file.
            if let path = entry.audioPath {
                let fileURL = audioDirectory.appendingPathComponent(path)
                try? fileManager.removeItem(at: fileURL)
            }
            // Update entry in cache: clear audioPath.
            if let idx = cachedEntries.firstIndex(where: { $0.id == entry.id }) {
                cachedEntries[idx] = cachedEntries[idx].withAudioPathCleared()
            }
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
        if cachedEntries.count > maxEntries {
            // Keep only the newest maxEntries.
            cachedEntries = Array(cachedEntries.prefix(maxEntries))
        }
    }

    /// Atomically rewrite the whole file in chronological (oldest-first) order.
    private func flush() {
        guard !loadFailed else { return }
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
        }
    }
}

// swiftlint:enable force_unwrapping
