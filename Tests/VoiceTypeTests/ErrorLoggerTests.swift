// ErrorLoggerTests.swift — VoiceType
//
// Unit tests for ErrorLogger:
// 1. Writes a log line to errors.log (canonical active file — not date-stamped).
// 2. Log line contains [category] and message.
// 3. Rotation archives errors.log from previous day → errors-YYYY-MM-DD.log.
// 4. Rotation deletes archives older than 7 days.
// 5. Rotation preserves archives within 7 days.
// 6. Context key=value pairs appear in the log line.
// 7. errors.log is never deleted by rotation/cleanup.
//
// DESIGN.md § Error Handling & Logging, Step 10.

import XCTest
@testable import VoiceType

@MainActor
final class ErrorLoggerTests: XCTestCase {

    // MARK: - Helpers

    private func makeLogger() -> (ErrorLogger, URL) {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("ErrorLoggerTests-\(UUID().uuidString)")
        let logger = ErrorLogger.test(logsDirectory: tempDir)
        return (logger, tempDir)
    }

    // MARK: - Write tests

    func testWritesLogLineToActiveFile() throws {
        let (logger, tempDir) = makeLogger()
        logger.log(message: "test error", category: "test")

        // Active file must always be errors.log — never a date-stamped name.
        let activeURL = tempDir.appendingPathComponent("errors.log")
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: activeURL.path),
            "errors.log must exist after first log() call"
        )
        let content = try String(contentsOf: logger.currentLogFileURL, encoding: .utf8)
        XCTAssertTrue(content.contains("[test] test error"), "Expected [test] category in log line, got: \(content)")
    }

    func testLogLineContainsISOTimestamp() throws {
        let (logger, _) = makeLogger()
        logger.log(message: "timestamp check", category: "test")

        let content = try String(contentsOf: logger.currentLogFileURL, encoding: .utf8)
        // ISO8601 starts with 4-digit year
        XCTAssertTrue(content.contains("202"), "Expected ISO timestamp in log line, got: \(content)")
    }

    func testLogLineContainsMessage() throws {
        let (logger, _) = makeLogger()
        logger.log(message: "something went wrong", category: "general")

        let content = try String(contentsOf: logger.currentLogFileURL, encoding: .utf8)
        XCTAssertTrue(content.contains("something went wrong"))
    }

    func testContextKeyValueAppearsInLine() throws {
        let (logger, _) = makeLogger()
        logger.log(message: "ctx test", category: "test", context: ["model": "tiny", "lang": "en"])

        let content = try String(contentsOf: logger.currentLogFileURL, encoding: .utf8)
        XCTAssertTrue(content.contains("model=tiny"), "Expected model=tiny in log, got: \(content)")
        XCTAssertTrue(content.contains("lang=en"), "Expected lang=en in log, got: \(content)")
    }

    func testMultipleWritesAppendToSameFile() throws {
        let (logger, _) = makeLogger()
        logger.log(message: "first", category: "test")
        logger.log(message: "second", category: "test")

        let content = try String(contentsOf: logger.currentLogFileURL, encoding: .utf8)
        XCTAssertTrue(content.contains("first"), "Expected 'first' in log")
        XCTAssertTrue(content.contains("second"), "Expected 'second' in log")
    }

    func testLogErrorObjectUsesLocalizedDescription() throws {
        let (logger, _) = makeLogger()
        let error = NSError(domain: "test", code: 42, userInfo: [NSLocalizedDescriptionKey: "custom error message"])
        logger.log(error, category: "test")

        let content = try String(contentsOf: logger.currentLogFileURL, encoding: .utf8)
        XCTAssertTrue(content.contains("custom error message"), "Expected error localizedDescription in log")
    }

    // MARK: - Rotation tests

    /// errors.log written on a previous day must be renamed to errors-YYYY-MM-DD.log,
    /// and the new log line must land in a fresh errors.log.
    func testRotationArchivesPreviousDay() throws {
        let (logger, tempDir) = makeLogger()
        let fileManager = FileManager.default

        let df = DateFormatter()
        df.dateFormat = "yyyy-MM-dd"
        df.locale = Locale(identifier: "en_US_POSIX")
        df.timeZone = .current
        let yesterday = df.string(from: Date().addingTimeInterval(-24 * 60 * 60))

        // Pre-seed errors.log with yesterday's content and backdate its mtime.
        let activeURL = tempDir.appendingPathComponent("errors.log")
        fileManager.createFile(atPath: activeURL.path, contents: Data("old entry\n".utf8))
        let yesterdayDate = Date().addingTimeInterval(-24 * 60 * 60)
        try fileManager.setAttributes([.modificationDate: yesterdayDate], ofItemAtPath: activeURL.path)

        // Writing today triggers rotation: errors.log → errors-{yesterday}.log.
        logger.log(message: "today entry", category: "test")

        let archiveURL = tempDir.appendingPathComponent("errors-\(yesterday).log")
        XCTAssertTrue(
            fileManager.fileExists(atPath: archiveURL.path),
            "Previous day's log must be archived as errors-\(yesterday).log"
        )
        let archiveContent = try String(contentsOf: archiveURL, encoding: .utf8)
        XCTAssertTrue(archiveContent.contains("old entry"), "Archive must contain previous day's content")

        XCTAssertTrue(
            fileManager.fileExists(atPath: activeURL.path),
            "errors.log must exist after rotation for the new day's writes"
        )
        let activeContent = try String(contentsOf: activeURL, encoding: .utf8)
        XCTAssertTrue(activeContent.contains("today entry"), "errors.log must contain today's new entry")
        XCTAssertFalse(activeContent.contains("old entry"), "errors.log must not contain previous day's content")
    }

    func testRotationDeletesArchivesOlderThanSevenDays() throws {
        let (logger, tempDir) = makeLogger()
        let fileManager = FileManager.default

        // Create a stale archive with an old date in its filename.
        let staleFile = tempDir.appendingPathComponent("errors-2020-01-01.log")
        fileManager.createFile(atPath: staleFile.path, contents: Data("old log line\n".utf8))

        // Write a new log line — this triggers rotation (which calls deleteStaleArchives).
        logger.log(message: "trigger rotation", category: "test")

        XCTAssertFalse(
            fileManager.fileExists(atPath: staleFile.path),
            "Stale archive should have been deleted by rotation"
        )
    }

    func testRotationPreservesArchivesWithinSevenDays() throws {
        let (logger, tempDir) = makeLogger()
        let fileManager = FileManager.default

        // Build a filename 3 days ago (within 7-day retention window).
        let df = DateFormatter()
        df.dateFormat = "yyyy-MM-dd"
        df.locale = Locale(identifier: "en_US_POSIX")
        df.timeZone = .current
        let threeDaysAgoString = df.string(from: Date().addingTimeInterval(-3 * 24 * 60 * 60))

        let recentFile = tempDir.appendingPathComponent("errors-\(threeDaysAgoString).log")
        fileManager.createFile(atPath: recentFile.path, contents: Data("recent log\n".utf8))

        // Trigger rotation.
        logger.log(message: "check retention", category: "test")

        XCTAssertTrue(
            fileManager.fileExists(atPath: recentFile.path),
            "Recent archive should NOT be deleted (within 7-day retention window)"
        )
    }

    /// errors.log must never be deleted by rotation or archive cleanup.
    func testRotationDoesNotDeleteActiveFile() throws {
        let (logger, tempDir) = makeLogger()
        let fileManager = FileManager.default

        // Write something so errors.log exists.
        logger.log(message: "first entry", category: "test")
        let activeURL = tempDir.appendingPathComponent("errors.log")
        XCTAssertTrue(fileManager.fileExists(atPath: activeURL.path), "errors.log must exist after first write")

        // Write more entries (triggers once-per-day rotation guard — no-op today).
        for i in 1...10 {
            logger.log(message: "entry \(i)", category: "test")
        }

        XCTAssertTrue(
            fileManager.fileExists(atPath: activeURL.path),
            "errors.log must never be deleted by rotation or archive cleanup"
        )
    }

    func testRotationIgnoresNonLogFiles() throws {
        let (logger, tempDir) = makeLogger()
        let fileManager = FileManager.default

        // Create an old non-log file in the directory.
        let otherFile = tempDir.appendingPathComponent("other-file.txt")
        fileManager.createFile(atPath: otherFile.path, contents: Data("data".utf8))

        let eightDaysAgo = Date().addingTimeInterval(-8 * 24 * 60 * 60)
        try fileManager.setAttributes(
            [.modificationDate: eightDaysAgo],
            ofItemAtPath: otherFile.path
        )

        logger.log(message: "trigger rotation", category: "test")

        // other-file.txt does not match "errors-*.log" pattern — must not be deleted.
        XCTAssertTrue(
            fileManager.fileExists(atPath: otherFile.path),
            "Non-log files should not be deleted by rotation"
        )
    }

    // MARK: - Rotation guard and filename-based cutoff

    /// Rotation should only scan the filesystem once per calendar day.
    /// Call log() 100 times — the result must be identical to calling it once
    /// (no extra deletions, and importantly: no crash / infinite loop).
    func testRotationOncePerDay() throws {
        let (logger, tempDir) = makeLogger()
        let fileManager = FileManager.default

        // Seed an old archive that rotation should delete.
        let staleFile = tempDir.appendingPathComponent("errors-2020-01-01.log")
        fileManager.createFile(atPath: staleFile.path, contents: Data("stale\n".utf8))

        // First log() call runs rotation and removes stale archive.
        logger.log(message: "first", category: "test")
        XCTAssertFalse(fileManager.fileExists(atPath: staleFile.path), "Stale archive must be gone after first log()")

        // Re-create the stale archive to detect if rotation runs again.
        fileManager.createFile(atPath: staleFile.path, contents: Data("stale-again\n".utf8))

        // 99 more log() calls — rotation guard must suppress the second scan.
        for i in 2...100 {
            logger.log(message: "iteration \(i)", category: "test")
        }

        // The re-created stale archive should still exist because rotation did NOT run again.
        XCTAssertTrue(
            fileManager.fileExists(atPath: staleFile.path),
            "Once-per-day guard must prevent a second rotation scan within the same day"
        )
    }

    /// Filename-based cutoff: an archive with an 8-day-old date in its name must be
    /// deleted even if its mtime is current (e.g. restored by Time Machine).
    /// Also verifies archives with optional .N collision suffix (errors-YYYY-MM-DD.1.log).
    func testRotationCutoffByFilename() throws {
        let (logger, tempDir) = makeLogger()
        let fileManager = FileManager.default

        let df = DateFormatter()
        df.dateFormat = "yyyy-MM-dd"
        df.locale = Locale(identifier: "en_US_POSIX")
        df.timeZone = .current

        let eightDaysAgoString = df.string(from: Date().addingTimeInterval(-8 * 24 * 60 * 60))
        let threeDaysAgoString = df.string(from: Date().addingTimeInterval(-3 * 24 * 60 * 60))

        let staleFile        = tempDir.appendingPathComponent("errors-\(eightDaysAgoString).log")
        let staleFileVariant = tempDir.appendingPathComponent("errors-\(eightDaysAgoString).1.log")
        let recentFile       = tempDir.appendingPathComponent("errors-\(threeDaysAgoString).log")

        fileManager.createFile(atPath: staleFile.path, contents: Data("stale\n".utf8))
        fileManager.createFile(atPath: staleFileVariant.path, contents: Data("stale-variant\n".utf8))
        fileManager.createFile(atPath: recentFile.path, contents: Data("recent\n".utf8))

        // Set CURRENT mtime on all files — filename-based code must delete only the 8-day ones.
        let now = Date()
        try fileManager.setAttributes([.modificationDate: now], ofItemAtPath: staleFile.path)
        try fileManager.setAttributes([.modificationDate: now], ofItemAtPath: staleFileVariant.path)
        try fileManager.setAttributes([.modificationDate: now], ofItemAtPath: recentFile.path)

        logger.log(message: "filename cutoff test", category: "test")

        XCTAssertFalse(
            fileManager.fileExists(atPath: staleFile.path),
            "8-day-old archive must be deleted regardless of current mtime"
        )
        XCTAssertFalse(
            fileManager.fileExists(atPath: staleFileVariant.path),
            "8-day-old archive with .N suffix must also be deleted"
        )
        XCTAssertTrue(
            fileManager.fileExists(atPath: recentFile.path),
            "3-day-old archive must be preserved (within 7-day retention window)"
        )
    }

    // MARK: - Directory creation

    func testCreatesLogsDirectoryIfMissing() throws {
        let tempBase = FileManager.default.temporaryDirectory
            .appendingPathComponent("ErrorLoggerTests-dir-\(UUID().uuidString)")
        let missingDir = tempBase.appendingPathComponent("VoiceType")

        // Directory does not exist yet.
        XCTAssertFalse(FileManager.default.fileExists(atPath: missingDir.path))

        let logger = ErrorLogger.test(logsDirectory: missingDir)
        logger.log(message: "create dir test", category: "test")

        XCTAssertTrue(
            FileManager.default.fileExists(atPath: missingDir.path),
            "ErrorLogger should create the logs directory on first write"
        )
    }
}
