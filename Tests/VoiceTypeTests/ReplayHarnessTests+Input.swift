import XCTest
@testable import VoiceType

// ReplayInput — pure input resolution (docs/plans/quality-tools.md §3.R1
// "Отбор входа"), covered by ReplayInputTests below (NOT XCTSkip-gated).
// Split out of ReplayHarnessTests.swift purely for the 600-line file_length
// warning threshold; kept in a file adjacent to (named after) the harness
// test, per that section's "чистая функция в том же файле теста".

enum ReplayInputError: Error, LocalizedError, Equatable {
    case malformedHistoryLine(line: Int, message: String)
    case duplicateKey(String)
    /// A sibling `.txt` reference exists but could not be read (not valid
    /// UTF-8, or a filesystem read error) — fail-closed, distinct from "no
    /// .txt file at all" (which is `nil` reference, not an error). P1 review
    /// finding: `try?` previously swallowed this into a silent `nil`.
    case unreadableReference(path: String, message: String)

    var errorDescription: String? {
        switch self {
        case let .malformedHistoryLine(line, message):
            return "history.jsonl line \(line): \(message)"
        case .duplicateKey(let key):
            return "duplicate replay key: \(key)"
        case let .unreadableReference(path, message):
            return "reference file exists but could not be read: \(path): \(message)"
        }
    }
}

enum ReplayInput {
    struct Record: Equatable {
        let key: String
        let audioURL: URL?
        let reference: String?
        let evalIssue: String?
        let historyEntry: HistoryStore.Entry?
    }

    /// Lists every `*.wav`/`*.caf` in `directoryURL`, sorted by filename,
    /// pairing each with a same-stem `.txt` reference if one exists. The key
    /// is the filename WITH extension, so `01.wav` and `01.caf` in the same
    /// directory are two distinct records, never a collision.
    static func resolveDirectory(_ directoryURL: URL, fileManager: FileManager = .default) throws -> [Record] {
        let names = try fileManager.contentsOfDirectory(atPath: directoryURL.path)
        let audioNames = names
            .filter { $0.hasSuffix(".wav") || $0.hasSuffix(".caf") }
            .sorted()

        var seen = Set<String>()
        var records: [Record] = []
        for name in audioNames {
            guard seen.insert(name).inserted else {
                throw ReplayInputError.duplicateKey(name)
            }
            let audioURL = directoryURL.appendingPathComponent(name)
            let stem = (name as NSString).deletingPathExtension
            let txtURL = directoryURL.appendingPathComponent(stem + ".txt")
            let reference: String?
            if fileManager.fileExists(atPath: txtURL.path) {
                do {
                    reference = try String(contentsOf: txtURL, encoding: .utf8)
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                } catch {
                    throw ReplayInputError.unreadableReference(path: txtURL.path, message: "\(error)")
                }
            } else {
                reference = nil
            }
            records.append(Record(key: name, audioURL: audioURL, reference: reference, evalIssue: nil, historyEntry: nil))
        }
        return records
    }

    /// Parses `history.jsonl` top-to-bottom — the file's own oldest-first
    /// order, which is what "LIMIT keeps the first N" means (the in-memory
    /// HistoryStore cache is newest-first; this reads the file directly).
    static func resolveHistory(
        historyURL: URL,
        audioDirectory: URL,
        onlySaved: Bool,
        limit: Int?
    ) throws -> [Record] {
        let content = try String(contentsOf: historyURL, encoding: .utf8)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601

        var records: [Record] = []
        var seen = Set<String>()
        for (index, rawLine) in content.components(separatedBy: "\n").enumerated() {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty else { continue }
            guard let lineData = line.data(using: .utf8) else {
                throw ReplayInputError.malformedHistoryLine(line: index + 1, message: "not valid UTF-8")
            }

            let entry: HistoryStore.Entry
            do {
                entry = try decoder.decode(HistoryStore.Entry.self, from: lineData)
            } catch {
                throw ReplayInputError.malformedHistoryLine(line: index + 1, message: "\(error)")
            }

            if onlySaved, entry.isSavedEval != true { continue }

            // Read independently of HistoryStore.Entry's Codable fields (raw
            // JSON, not a decoded property): T3 (parallel worktree) adds
            // Entry.evalIssue, and this must extract the same key correctly
            // both before and after that field lands, without depending on it.
            var evalIssue: String?
            if let object = try? JSONSerialization.jsonObject(with: lineData) as? [String: Any] {
                evalIssue = object["evalIssue"] as? String
            }

            let key = entry.id.uuidString
            guard seen.insert(key).inserted else {
                throw ReplayInputError.duplicateKey(key)
            }

            let audioURL = entry.audioPath.map { audioDirectory.appendingPathComponent($0) }
            records.append(Record(
                key: key,
                audioURL: audioURL,
                reference: entry.userCorrection,
                evalIssue: evalIssue,
                historyEntry: entry
            ))
        }

        if let limit {
            return Array(records.prefix(limit))
        }
        return records
    }
}

// MARK: - ReplayInput unit tests — NOT XCTSkip-gated, always run.

final class ReplayInputTests: XCTestCase {

    private func makeTempDirectory() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("ReplayInputTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        return dir
    }

    private func historyLine(
        id: String,
        text: String = "hello",
        audioPath: String? = "a.caf",
        isSavedEval: Bool? = nil,
        userCorrection: String? = nil,
        extraKeys: String = ""
    ) -> String {
        var fields = [
            "\"id\":\"\(id)\"",
            "\"timestamp\":\"2026-09-01T09:00:00Z\"",
            "\"text\":\"\(text)\"",
            "\"charCount\":\(text.count)",
            "\"targetAppName\":\"TestApp\"",
            "\"targetAppBundleID\":\"com.test\"",
            "\"language\":\"en\""
        ]
        if let audioPath { fields.append("\"audioPath\":\"\(audioPath)\"") }
        if let isSavedEval { fields.append("\"isSavedEval\":\(isSavedEval)") }
        if let userCorrection { fields.append("\"userCorrection\":\"\(userCorrection)\"") }
        var joined = fields.joined(separator: ",")
        if !extraKeys.isEmpty { joined += "," + extraKeys }
        return "{\(joined)}"
    }

    // MARK: Directory mode

    func testResolveDirectory_empty() throws {
        let dir = try makeTempDirectory()
        let records = try ReplayInput.resolveDirectory(dir)
        XCTAssertEqual(records, [])
    }

    func testResolveDirectory_pairsReferenceTxt() throws {
        let dir = try makeTempDirectory()
        try Data().write(to: dir.appendingPathComponent("01.wav"))
        try "hello world".write(to: dir.appendingPathComponent("01.txt"), atomically: true, encoding: .utf8)
        try Data().write(to: dir.appendingPathComponent("02.wav"))

        let records = try ReplayInput.resolveDirectory(dir)
        XCTAssertEqual(records.count, 2)
        XCTAssertEqual(records[0].key, "01.wav")
        XCTAssertEqual(records[0].reference, "hello world")
        XCTAssertEqual(records[1].key, "02.wav")
        XCTAssertNil(records[1].reference)
    }

    func testResolveDirectory_invalidUTF8ReferenceThrows() throws {
        let dir = try makeTempDirectory()
        try Data().write(to: dir.appendingPathComponent("01.wav"))
        // 0xFF 0xFE 0xFD is not valid UTF-8 — the .txt file EXISTS, so this
        // must fail closed (throw), not silently resolve to a nil reference.
        try Data([0xFF, 0xFE, 0xFD]).write(to: dir.appendingPathComponent("01.txt"))

        XCTAssertThrowsError(try ReplayInput.resolveDirectory(dir)) { error in
            guard case .unreadableReference? = error as? ReplayInputError else {
                XCTFail("expected .unreadableReference, got \(error)")
                return
            }
        }
    }

    func testResolveDirectory_wavAndCafSameStemAreDistinctKeys() throws {
        let dir = try makeTempDirectory()
        try Data().write(to: dir.appendingPathComponent("01.wav"))
        try Data().write(to: dir.appendingPathComponent("01.caf"))

        let records = try ReplayInput.resolveDirectory(dir)
        XCTAssertEqual(Set(records.map(\.key)), ["01.wav", "01.caf"])
    }

    // MARK: History mode

    func testResolveHistory_empty() throws {
        let dir = try makeTempDirectory()
        let historyURL = dir.appendingPathComponent("history.jsonl")
        try "".write(to: historyURL, atomically: true, encoding: .utf8)

        let records = try ReplayInput.resolveHistory(
            historyURL: historyURL, audioDirectory: dir, onlySaved: false, limit: nil
        )
        XCTAssertEqual(records, [])
    }

    func testResolveHistory_onlySavedFilter() throws {
        let dir = try makeTempDirectory()
        let historyURL = dir.appendingPathComponent("history.jsonl")
        let lines = [
            historyLine(id: "00000000-0000-0000-0000-000000000001", isSavedEval: true),
            historyLine(id: "00000000-0000-0000-0000-000000000002", isSavedEval: nil),
            historyLine(id: "00000000-0000-0000-0000-000000000003", isSavedEval: false)
        ]
        try lines.joined(separator: "\n").write(to: historyURL, atomically: true, encoding: .utf8)

        let all = try ReplayInput.resolveHistory(historyURL: historyURL, audioDirectory: dir, onlySaved: false, limit: nil)
        XCTAssertEqual(all.count, 3)

        let saved = try ReplayInput.resolveHistory(historyURL: historyURL, audioDirectory: dir, onlySaved: true, limit: nil)
        XCTAssertEqual(saved.map(\.key), ["00000000-0000-0000-0000-000000000001"])
    }

    func testResolveHistory_limitKeepsFileOrder() throws {
        let dir = try makeTempDirectory()
        let historyURL = dir.appendingPathComponent("history.jsonl")
        let lines = (1...5).map {
            historyLine(id: String(format: "00000000-0000-0000-0000-%012d", $0))
        }
        try lines.joined(separator: "\n").write(to: historyURL, atomically: true, encoding: .utf8)

        let records = try ReplayInput.resolveHistory(historyURL: historyURL, audioDirectory: dir, onlySaved: false, limit: 2)
        XCTAssertEqual(records.map(\.key), [
            "00000000-0000-0000-0000-000000000001",
            "00000000-0000-0000-0000-000000000002"
        ])
    }

    func testResolveHistory_recordWithoutAudioPathHasNilAudioURL() throws {
        let dir = try makeTempDirectory()
        let historyURL = dir.appendingPathComponent("history.jsonl")
        try historyLine(id: "00000000-0000-0000-0000-000000000001", audioPath: nil)
            .write(to: historyURL, atomically: true, encoding: .utf8)

        let records = try ReplayInput.resolveHistory(historyURL: historyURL, audioDirectory: dir, onlySaved: false, limit: nil)
        XCTAssertEqual(records.count, 1)
        XCTAssertNil(records[0].audioURL)
    }

    func testResolveHistory_evalIssuePresentAndAbsent() throws {
        let dir = try makeTempDirectory()
        let historyURL = dir.appendingPathComponent("history.jsonl")
        let lines = [
            historyLine(id: "00000000-0000-0000-0000-000000000001", extraKeys: "\"evalIssue\":\"asr\""),
            historyLine(id: "00000000-0000-0000-0000-000000000002")
        ]
        try lines.joined(separator: "\n").write(to: historyURL, atomically: true, encoding: .utf8)

        let records = try ReplayInput.resolveHistory(historyURL: historyURL, audioDirectory: dir, onlySaved: false, limit: nil)
        XCTAssertEqual(records.count, 2)
        XCTAssertEqual(records[0].evalIssue, "asr")
        XCTAssertNil(records[1].evalIssue)
    }

    func testResolveHistory_duplicateIDThrows() throws {
        let dir = try makeTempDirectory()
        let historyURL = dir.appendingPathComponent("history.jsonl")
        let lines = [
            historyLine(id: "00000000-0000-0000-0000-000000000001"),
            historyLine(id: "00000000-0000-0000-0000-000000000001")
        ]
        try lines.joined(separator: "\n").write(to: historyURL, atomically: true, encoding: .utf8)

        XCTAssertThrowsError(
            try ReplayInput.resolveHistory(historyURL: historyURL, audioDirectory: dir, onlySaved: false, limit: nil)
        ) { error in
            XCTAssertEqual(error as? ReplayInputError, .duplicateKey("00000000-0000-0000-0000-000000000001"))
        }
    }

    func testResolveHistory_malformedLineReportsLineNumber() throws {
        let dir = try makeTempDirectory()
        let historyURL = dir.appendingPathComponent("history.jsonl")
        let lines = [
            historyLine(id: "00000000-0000-0000-0000-000000000001"),
            "{ this is not valid json",
            historyLine(id: "00000000-0000-0000-0000-000000000002")
        ]
        try lines.joined(separator: "\n").write(to: historyURL, atomically: true, encoding: .utf8)

        XCTAssertThrowsError(
            try ReplayInput.resolveHistory(historyURL: historyURL, audioDirectory: dir, onlySaved: false, limit: nil)
        ) { error in
            guard case let .malformedHistoryLine(line, _)? = error as? ReplayInputError else {
                XCTFail("expected .malformedHistoryLine, got \(error)")
                return
            }
            XCTAssertEqual(line, 2)
        }
    }
}
