// ErrorLogger.swift — VoiceType
//
// File-based error logger. Writes to ~/Library/Logs/VoiceType/errors.log (canonical,
// always the active file). On day rollover the previous day's errors.log is renamed
// to errors-YYYY-MM-DD.log (archive). 7-day retention: archives older than 7 days
// are deleted on each write. errors.log itself is never deleted.
// Does NOT replace OSLog (AppLog.*) — callers use both. ErrorLogger is file-only
// persistence for the "View log" link in the toast.
//
// DESIGN.md § Error Handling & Logging, Step 10.

import Foundation
import OSLog

// swiftlint:disable force_unwrapping

/// File-based error logger. Writes to ~/Library/Logs/VoiceType/errors.log (canonical
/// active path). On day rollover the previous file is archived as errors-YYYY-MM-DD.log.
/// 7-day retention applies to archives only — errors.log is never deleted.
@MainActor
final class ErrorLogger {

    // MARK: - Shared

    static let shared = ErrorLogger()

    // MARK: - Private state

    private let logsDirectory: URL
    private let fileManager = FileManager.default
    private let isoFormatter = ISO8601DateFormatter()
    /// Tracks which calendar day rotation was last performed.
    /// Prevents repeated expensive filesystem scans within the same day.
    private var lastRotationDay: String?
    private let dateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = .current
        return f
    }()

    // MARK: - Init (private + test seam)

    private init(logsDirectory: URL?) {
        if let custom = logsDirectory {
            self.logsDirectory = custom
        } else {
            let libraryLogs = FileManager.default
                .urls(for: .libraryDirectory, in: .userDomainMask)
                .first!
                .appendingPathComponent("Logs")
            self.logsDirectory = libraryLogs.appendingPathComponent("VoiceType")
        }
        try? fileManager.createDirectory(
            at: self.logsDirectory,
            withIntermediateDirectories: true
        )
    }

    /// Production init (shared singleton path).
    convenience init() {
        self.init(logsDirectory: nil)
    }

    /// Test seam — initialised with a temp directory so tests are hermetic.
    static func test(logsDirectory: URL) -> ErrorLogger {
        ErrorLogger(logsDirectory: logsDirectory)
    }

    // MARK: - Public API

    /// Log an `Error` value. `category` maps to AppLog category names for traceability.
    func log(_ error: Error, category: String = "general", context: [String: String] = [:]) {
        log(message: error.localizedDescription, category: category, context: context)
    }

    /// Log a plain message string.
    func log(message: String, category: String = "general", context: [String: String] = [:]) {
        rotateIfNeeded()
        let timestamp = isoFormatter.string(from: Date())
        let contextStr = context.isEmpty
            ? ""
            : " " + context.map { "\($0.key)=\($0.value)" }.sorted().joined(separator: " ")
        let line = "[\(timestamp)] [\(category)] \(message)\(contextStr)\n"
        appendLine(line)
    }

    // MARK: - File URL accessors

    /// Canonical active log file. Always ~/Library/Logs/VoiceType/errors.log.
    /// This is the path DESIGN.md and Settings diagnostics copy point users to.
    var currentLogFileURL: URL {
        logsDirectory.appendingPathComponent("errors.log")
    }

    /// Logs directory (~/Library/Logs/VoiceType/ in production).
    var logDirectoryURL: URL {
        logsDirectory
    }

    // MARK: - Private helpers

    private func appendLine(_ line: String) {
        let url = currentLogFileURL
        if !fileManager.fileExists(atPath: url.path) {
            fileManager.createFile(atPath: url.path, contents: nil)
        }
        guard let data = line.data(using: .utf8) else { return }
        guard let handle = try? FileHandle(forWritingTo: url) else { return }
        defer { try? handle.close() }
        try? handle.seekToEnd()
        try? handle.write(contentsOf: data)
    }

    /// Archive the previous day's errors.log (if any) and purge stale archives.
    /// Must be called before appending so the new line lands in the fresh active file.
    private func rotateIfNeeded() {
        let today = dateFormatter.string(from: Date())
        if lastRotationDay == today { return }

        let activeURL = logsDirectory.appendingPathComponent("errors.log")

        // If errors.log exists and was last written on a previous day, archive it.
        if fileManager.fileExists(atPath: activeURL.path),
           let attrs = try? fileManager.attributesOfItem(atPath: activeURL.path),
           let mtime = attrs[.modificationDate] as? Date {
            let mtimeDay = dateFormatter.string(from: mtime)
            if mtimeDay != today {
                let archiveURL = logsDirectory.appendingPathComponent("errors-\(mtimeDay).log")
                // Collision guard (rare — e.g. two processes, or mtime drift).
                var finalArchive = archiveURL
                var counter = 1
                while fileManager.fileExists(atPath: finalArchive.path) {
                    finalArchive = logsDirectory
                        .appendingPathComponent("errors-\(mtimeDay).\(counter).log")
                    counter += 1
                }
                try? fileManager.moveItem(at: activeURL, to: finalArchive)
                AppLog.app.notice(
                    "ErrorLogger: archived \(activeURL.lastPathComponent, privacy: .public) → \(finalArchive.lastPathComponent, privacy: .public)"
                )
            }
        }

        deleteStaleArchives()
        lastRotationDay = today
    }

    /// Delete date-stamped archives older than 7 days. Never touches errors.log.
    private func deleteStaleArchives() {
        let cutoffString = dateFormatter.string(
            from: Date().addingTimeInterval(-7 * 24 * 60 * 60)
        )
        guard let files = try? fileManager.contentsOfDirectory(
            at: logsDirectory,
            includingPropertiesForKeys: nil
        ) else { return }

        for url in files where url.pathExtension == "log" {
            let stem = url.deletingPathExtension().lastPathComponent
            // Only consider archive-shaped names: errors-YYYY-MM-DD or errors-YYYY-MM-DD.N
            guard stem.hasPrefix("errors-") else { continue }
            let datePart = stem.dropFirst("errors-".count)
            // Take the first 10 chars (YYYY-MM-DD) for comparison.
            let dateString = String(datePart.prefix(10))
            guard dateString.count == 10 else { continue }
            // ISO date string comparison is lexicographically equivalent to chronological.
            if dateString < cutoffString {
                try? fileManager.removeItem(at: url)
                AppLog.app.notice("ErrorLogger: deleted old archive \(url.lastPathComponent, privacy: .public)")
            }
        }
    }
}

// swiftlint:enable force_unwrapping
