// HistoryStore.swift — VoiceType
//
// Append-only JSONL store for transcription history.
// File: ~/Library/Application Support/VoiceType/history.jsonl
// Rolling cap: 100 entries (oldest evicted on insert).
// In-memory cache + atomic flush-on-write. Re-writes whole file each time
// (acceptable: ≤100 entries, measured at ~40µs).
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

        init(
            text: String,
            targetAppName: String,
            targetAppBundleID: String?,
            language: String
        ) {
            self.id = UUID()
            self.timestamp = Date()
            self.text = text
            self.charCount = text.count
            self.targetAppName = targetAppName
            self.targetAppBundleID = targetAppBundleID
            self.language = language
        }
    }

    // MARK: - Private state

    private let storeURL: URL
    private let maxEntries: Int = 100
    private let fileManager = FileManager.default
    /// Newest-first ordering in memory.
    private var cachedEntries: [Entry] = []
    private var loaded: Bool = false

    // MARK: - Init

    private init(storeURL: URL? = nil) {
        if let custom = storeURL {
            self.storeURL = custom
        } else {
            let appSupport = fileManager.urls(
                for: .applicationSupportDirectory,
                in: .userDomainMask
            ).first!
            let voiceTypeDir = appSupport.appendingPathComponent("VoiceType")
            try? fileManager.createDirectory(at: voiceTypeDir, withIntermediateDirectories: true)
            self.storeURL = voiceTypeDir.appendingPathComponent("history.jsonl")
        }
    }

    /// Test seam — pass a temp-dir URL so tests are hermetic.
    static func test(storeURL: URL) -> HistoryStore {
        HistoryStore(storeURL: storeURL)
    }

    // MARK: - Public API

    /// Append a new entry. Evicts oldest when cap is exceeded. Flushes to disk.
    func append(_ entry: Entry) {
        loadIfNeeded()
        cachedEntries.insert(entry, at: 0)
        if cachedEntries.count > maxEntries {
            cachedEntries.removeLast(cachedEntries.count - maxEntries)
        }
        flush()
    }

    /// All entries, newest first.
    func entries() -> [Entry] {
        loadIfNeeded()
        return cachedEntries
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

    // MARK: - Private helpers

    private func loadIfNeeded() {
        guard !loaded else { return }
        loaded = true
        guard fileManager.fileExists(atPath: storeURL.path),
              let data = try? Data(contentsOf: storeURL),
              let raw = String(data: data, encoding: .utf8) else {
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
