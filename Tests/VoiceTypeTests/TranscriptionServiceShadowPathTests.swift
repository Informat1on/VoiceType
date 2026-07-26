// TranscriptionServiceShadowPathTests.swift — VoiceType
//
// Coverage for TranscriptionService.shadowModelURL(for:) — the ".metal-only"
// symlink farm that lets loadModel route whisper.cpp's encoder away from
// CoreML/ANE without patching whisper.cpp or moving/deleting the real model
// file. See the doc comment on shadowModelURL for the mechanism
// (whisper_get_coreml_path_encoder derives the CoreML path from the *string*
// handed to Whisper(fromFileURL:), not from a resolved real path).
//
// Pure filesystem logic, entirely independent of a real Whisper context —
// exercised directly here rather than through loadModel().

import XCTest
@testable import VoiceType

@MainActor
final class TranscriptionServiceShadowPathTests: XCTestCase {

    // swiftlint:disable:next implicitly_unwrapped_optional
    private var tempDir: URL!
    private let fm = FileManager.default

    override func setUp() async throws {
        try await super.setUp()
        tempDir = fm.temporaryDirectory.appendingPathComponent(
            "TranscriptionServiceShadowPathTests-\(UUID().uuidString)",
            isDirectory: true
        )
        try fm.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        try? fm.removeItem(at: tempDir)
        tempDir = nil
        try await super.tearDown()
    }

    // MARK: - Helpers

    @discardableResult
    private func writeModelFile(named name: String = "ggml-tiny.bin", contents: String = "fake-model-bytes") throws -> URL {
        let url = tempDir.appendingPathComponent(name)
        try Data(contents.utf8).write(to: url)
        return url
    }

    private func shadowDir(for modelURL: URL) -> URL {
        modelURL.deletingLastPathComponent().appendingPathComponent(".metal-only", isDirectory: true)
    }

    // MARK: - Fresh install

    func testShadowModelURLCreatesRelativeSymlinkNextToRealFile() throws {
        let modelURL = try writeModelFile()

        let shadowURL = try TranscriptionService.shadowModelURL(for: modelURL)

        XCTAssertEqual(shadowURL.path, shadowDir(for: modelURL).appendingPathComponent("ggml-tiny.bin").path)
        let destination = try fm.destinationOfSymbolicLink(atPath: shadowURL.path)
        XCTAssertEqual(destination, "../ggml-tiny.bin", "must be a relative symlink so the whole Models dir stays relocatable")

        // whisper.cpp opens this exact path to read the model — prove the real
        // bytes are reachable straight through the shadow symlink.
        let readBack = try Data(contentsOf: shadowURL)
        XCTAssertEqual(String(bytes: readBack, encoding: .utf8), "fake-model-bytes")
    }

    // MARK: - Reuse

    func testShadowModelURLReusesAnAlreadyCorrectSymlinkInPlace() throws {
        let modelURL = try writeModelFile()

        let first = try TranscriptionService.shadowModelURL(for: modelURL)
        let inodeBefore = try fm.attributesOfItem(atPath: first.path)[.systemFileNumber] as? Int

        let second = try TranscriptionService.shadowModelURL(for: modelURL)
        let inodeAfter = try fm.attributesOfItem(atPath: second.path)[.systemFileNumber] as? Int

        let reuseMessage = "an already-correct symlink must be reused in place, never recreated — a concurrent " +
            "loadModel() call could be mid-open() on the existing inode (see modelLoadGeneration doc)"
        XCTAssertEqual(second.path, first.path)
        XCTAssertNotNil(inodeBefore)
        XCTAssertEqual(inodeBefore, inodeAfter, reuseMessage)

        // No leftover ".shadow-<uuid>" temp entries from an atomic-install that
        // never needed to happen.
        let entries = try fm.contentsOfDirectory(atPath: shadowDir(for: modelURL).path)
        XCTAssertEqual(entries, ["ggml-tiny.bin"])
    }

    // MARK: - Atomic replace of a stale symlink

    func testShadowModelURLReplacesAStaleSymlinkAtomically() throws {
        let modelURL = try writeModelFile()
        let shadowDirURL = shadowDir(for: modelURL)
        try fm.createDirectory(at: shadowDirURL, withIntermediateDirectories: true)
        // Simulate a leftover symlink from a previous/renamed model pointing elsewhere.
        try fm.createSymbolicLink(
            atPath: shadowDirURL.appendingPathComponent("ggml-tiny.bin").path,
            withDestinationPath: "../some-other-file.bin"
        )

        let shadowURL = try TranscriptionService.shadowModelURL(for: modelURL)

        let destination = try fm.destinationOfSymbolicLink(atPath: shadowURL.path)
        XCTAssertEqual(destination, "../ggml-tiny.bin")

        let entries = try fm.contentsOfDirectory(atPath: shadowDirURL.path)
        XCTAssertEqual(entries, ["ggml-tiny.bin"], "rename() must leave no .shadow-<uuid> temp entry behind")
    }

    // MARK: - Hard-error edge cases (never silently fall back to the real url)

    func testShadowModelURLThrowsWhenNonSymlinkOccupiesTheTargetPath() throws {
        let modelURL = try writeModelFile()
        let shadowDirURL = shadowDir(for: modelURL)
        try fm.createDirectory(at: shadowDirURL, withIntermediateDirectories: true)
        // A stray regular file at the target path must never be silently clobbered.
        try Data("unexpected".utf8).write(to: shadowDirURL.appendingPathComponent("ggml-tiny.bin"))

        XCTAssertThrowsError(try TranscriptionService.shadowModelURL(for: modelURL))
    }

    func testShadowModelURLThrowsWhenShadowDirectoryPathIsARegularFile() throws {
        let modelURL = try writeModelFile()
        // .metal-only exists as a plain file instead of a directory.
        try Data("not-a-directory".utf8).write(to: shadowDir(for: modelURL))

        XCTAssertThrowsError(try TranscriptionService.shadowModelURL(for: modelURL))
    }
}
