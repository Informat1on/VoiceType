import XCTest
@testable import VoiceType

// Offline harness: runs the REAL post-processing chain over a corpus on disk
// and writes its output for `scripts/categorized-eval.py` to score.
//
// Why a test and not a CLI target: the package ships a single executable (the
// app). Adding a second product just to score a corpus would put an eval tool
// into the release build. A test target already links the production code, so
// the measurement runs against exactly what ships.
//
// Skipped unless VOICETYPE_DUMP_IN is set, so CI and ordinary `swift test`
// runs are unaffected. The corpus itself is local-only (the repository is
// public and the audio is the owner's real speech), which is why no path is
// hardcoded here.
//
//   VOICETYPE_DUMP_IN=<dir with NN.raw.txt> \
//   VOICETYPE_DUMP_OUT=<dir for NN.out.txt> \
//     swift test --filter CorpusDumpTests
@MainActor
final class CorpusDumpTests: XCTestCase {

    func testDumpNormalizedCorpus() throws {
        let env = ProcessInfo.processInfo.environment
        guard let inPath = env["VOICETYPE_DUMP_IN"],
              let outPath = env["VOICETYPE_DUMP_OUT"] else {
            throw XCTSkip("VOICETYPE_DUMP_IN / VOICETYPE_DUMP_OUT not set — offline harness only")
        }

        let fm = FileManager.default
        let inDir = URL(fileURLWithPath: inPath)
        let outDir = URL(fileURLWithPath: outPath)
        try fm.createDirectory(at: outDir, withIntermediateDirectories: true)

        let rawFiles = try fm.contentsOfDirectory(atPath: inPath)
            .filter { $0.hasSuffix(".raw.txt") }
            .sorted()
        XCTAssertFalse(rawFiles.isEmpty, "No .raw.txt files in \(inPath)")

        for file in rawFiles {
            let raw = try String(contentsOf: inDir.appendingPathComponent(file), encoding: .utf8)

            // The corpus stores joined text, not whisper segments: these are
            // history entries, and history never kept segment boundaries.
            // Passing the whole text as a single segment is faithful for the
            // normalizer (which works on joined text anyway) and inert for the
            // hallucination filter (no corpus record is boilerplate — verified
            // separately on the 1000-file relabeled set, which does have
            // segment boundaries).
            let result = TranscriptionService.postProcess(segments: [raw], trim: false)

            let n = file.replacingOccurrences(of: ".raw.txt", with: "")
            try result.text.write(
                to: outDir.appendingPathComponent("\(n).out.txt"),
                atomically: true,
                encoding: .utf8
            )
        }
    }

    /// Runs the chain over a JSONL corpus (one object per line with a `text`
    /// field) and writes a JSONL report: input, output, and which boilerplate
    /// segments the filter dropped.
    ///
    /// Segments are reconstructed by splitting on "\n", which is how
    /// `whisper-cli` prints them (one line per segment). That is the only
    /// corpus that carries segment boundaries at all — the app's own history
    /// stores joined text with no newlines.
    func testDumpJSONLCorpus() throws {
        let env = ProcessInfo.processInfo.environment
        guard let inPath = env["VOICETYPE_JSONL_IN"],
              let outPath = env["VOICETYPE_JSONL_OUT"] else {
            throw XCTSkip("VOICETYPE_JSONL_IN / VOICETYPE_JSONL_OUT not set — offline harness only")
        }

        let content = try String(contentsOf: URL(fileURLWithPath: inPath), encoding: .utf8)
        var lines: [String] = []

        for line in content.split(separator: "\n", omittingEmptySubsequences: true) {
            guard let data = line.data(using: .utf8),
                  let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let text = object["text"] as? String else { continue }

            // Splitting on "\n" is only correct for a corpus whose newlines
            // ARE segment boundaries (a `whisper-cli` dump). For the app's own
            // corpus the text is already joined and carries no segment
            // information, so it must be passed whole — splitting there would
            // silently drop the newlines on rejoin and glue words together
            // across lines, which looks exactly like a normalizer defect.
            let segments = env["VOICETYPE_JSONL_SPLIT"] == "1"
                ? text.components(separatedBy: "\n")
                : [text]
            let result = TranscriptionService.postProcess(segments: segments, trim: false)

            let report: [String: Any] = [
                "input": text,
                "output": result.text,
                "removed": result.removedTemplates
            ]
            let encoded = try JSONSerialization.data(withJSONObject: report)
            guard let encodedLine = String(data: encoded, encoding: .utf8) else { continue }
            lines.append(encodedLine)
        }

        try lines.joined(separator: "\n").write(
            to: URL(fileURLWithPath: outPath), atomically: true, encoding: .utf8)
    }
}
