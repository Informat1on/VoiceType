// ModelManagerTests.swift — VoiceType
//
// Tests for four ModelManager bug fixes found in code review:
//   1. deleteModel must not remove a CoreML encoder still referenced by
//      another downloaded model (largeV3Turbo / largeV3TurboQ5 share one
//      encoder — see TranscriptionModel.coreMLFileName).
//   2. needsCoreMLDownload must never request an encoder for a model that
//      doesn't ship one (small-q5_1 — hasCoreMLSupport == false).
//   3. (covered by code review, not unit-testable without a real .zip and a
//      real /usr/bin/unzip run: atomic install via a same-volume scratch dir
//      + validate-before-swap in installCoreMLBundle.)
//   4. isValidCoreMLBundle must structurally reject a corrupted/incomplete
//      `.mlmodelc` directory, not just check "exists and non-empty".
//
// ModelManager.shared is a process-wide singleton that resolves to the real
// ~/Library/Application Support/VoiceType/Models directory by default. Every
// test below redirects it to an isolated temp directory via
// `_testModelsDirectoryOverride` and clears the override in tearDown — this
// must NEVER be left pointing at a temp dir afterwards, or later tests (or
// the app itself, if ever run in-process) would read/write there instead of
// the owner's real Models folder.

import XCTest
@testable import VoiceType

@MainActor
final class ModelManagerTests: XCTestCase {

    // swiftlint:disable:next implicitly_unwrapped_optional
    private var tempDir: URL!
    private let fm = FileManager.default

    override func setUp() async throws {
        try await super.setUp()
        tempDir = fm.temporaryDirectory.appendingPathComponent(
            "ModelManagerTests-\(UUID().uuidString)",
            isDirectory: true
        )
        try fm.createDirectory(at: tempDir, withIntermediateDirectories: true)
        ModelManager.shared._testModelsDirectoryOverride = tempDir
    }

    override func tearDown() async throws {
        ModelManager.shared._testModelsDirectoryOverride = nil
        try? fm.removeItem(at: tempDir)
        tempDir = nil
        try await super.tearDown()
    }

    // MARK: - Helpers

    /// Creates a minimal-but-valid `.mlmodelc` bundle at `url`, matching the
    /// structural check in ModelManager.isValidCoreMLBundle (non-empty
    /// coremldata.bin + model.mil). Mirrors the real bundle layout found
    /// under ~/Library/Application Support/VoiceType/Models on this machine
    /// (which also has metadata.json / weights/ / analytics/ — deliberately
    /// not required here, since the check is a minimum, not a full manifest).
    private func writeValidBundle(at url: URL) throws {
        try fm.createDirectory(at: url, withIntermediateDirectories: true)
        try Data([0x01]).write(to: url.appendingPathComponent("coremldata.bin"))
        try Data([0x02]).write(to: url.appendingPathComponent("model.mil"))
    }

    private func writeMainModelFile(for model: TranscriptionModel) throws {
        try Data([0x00]).write(to: ModelManager.shared.modelURL(for: model))
    }

    // MARK: - Bug 1: deleteModel must not remove an encoder shared with another downloaded model

    func testDeletingLargeV3TurboKeepsSharedEncoderWhenQ5StillDownloaded() throws {
        // Both largeV3Turbo and largeV3TurboQ5 point at the same coreMLFileName.
        try writeMainModelFile(for: .largeV3Turbo)
        try writeMainModelFile(for: .largeV3TurboQ5)
        try writeValidBundle(at: ModelManager.shared.coreMLModelURL(for: .largeV3Turbo))

        try ModelManager.shared.deleteModel(model: .largeV3Turbo)

        XCTAssertFalse(
            ModelManager.shared.isModelDownloaded(model: .largeV3Turbo),
            "largeV3Turbo's own .bin must still be deleted"
        )
        XCTAssertTrue(
            ModelManager.shared.isCoreMLModelDownloaded(model: .largeV3TurboQ5),
            "Shared encoder must survive because largeV3TurboQ5 is still downloaded (bug 1)"
        )
    }

    func testDeletingLastModelReferencingEncoderRemovesIt() throws {
        // Only largeV3Turbo references the encoder here — no other downloaded
        // model needs it, so it must actually be cleaned up (regression guard
        // for the opposite direction of bug 1).
        try writeMainModelFile(for: .largeV3Turbo)
        try writeValidBundle(at: ModelManager.shared.coreMLModelURL(for: .largeV3Turbo))

        try ModelManager.shared.deleteModel(model: .largeV3Turbo)

        XCTAssertFalse(
            ModelManager.shared.isCoreMLModelDownloaded(model: .largeV3Turbo),
            "Encoder must be removed once no downloaded model references it"
        )
    }

    // MARK: - Bug 2: small-q5_1 must never request a CoreML download

    func testSmallQ5DoesNotRequestCoreMLDownload() {
        XCTAssertFalse(
            TranscriptionModel.smallQ5.hasCoreMLSupport,
            "Precondition: small-q5_1 has no CoreML variant on HuggingFace"
        )
        XCTAssertFalse(
            ModelManager.shared.needsCoreMLDownload(for: .smallQ5),
            "needsCoreMLDownload must short-circuit on hasCoreMLSupport == false (bug 2)"
        )
    }

    func testModelsWithCoreMLSupportRequestDownloadWhenNotPresent() {
        // Sanity check for the other side of the branch: a model that DOES
        // ship a CoreML variant, with nothing on disk, must request one.
        XCTAssertTrue(ModelManager.shared.needsCoreMLDownload(for: .largeV3Turbo))
    }

    // MARK: - Bug 4: CoreML bundle validation must be structural, not just "non-empty"

    func testValidBundlePassesValidation() throws {
        let bundleURL = tempDir.appendingPathComponent("ggml-large-v3-turbo-encoder.mlmodelc")
        try writeValidBundle(at: bundleURL)

        XCTAssertTrue(ModelManager.shared.isValidCoreMLBundle(at: bundleURL))
    }

    func testEmptyDirectoryFailsValidation() throws {
        // This is the exact case the old isDirectoryNotEmpty check missed:
        // "exists and non-empty" said nothing about a corrupted install.
        let bundleURL = tempDir.appendingPathComponent("ggml-large-v3-turbo-encoder.mlmodelc")
        try fm.createDirectory(at: bundleURL, withIntermediateDirectories: true)

        XCTAssertFalse(
            ModelManager.shared.isValidCoreMLBundle(at: bundleURL),
            "An empty directory must not count as a downloaded encoder (bug 4)"
        )
    }

    func testDirectoryMissingModelMilFailsValidation() throws {
        // Corrupted / partial unzip: coremldata.bin landed but model.mil didn't.
        let bundleURL = tempDir.appendingPathComponent("ggml-large-v3-turbo-encoder.mlmodelc")
        try fm.createDirectory(at: bundleURL, withIntermediateDirectories: true)
        try Data([0x01]).write(to: bundleURL.appendingPathComponent("coremldata.bin"))

        XCTAssertFalse(
            ModelManager.shared.isValidCoreMLBundle(at: bundleURL),
            "A bundle missing model.mil must fail validation (bug 4)"
        )
    }

    func testZeroByteRequiredFileFailsValidation() throws {
        // A truncated write (e.g. an interrupted unzip) can leave a 0-byte file.
        let bundleURL = tempDir.appendingPathComponent("ggml-large-v3-turbo-encoder.mlmodelc")
        try fm.createDirectory(at: bundleURL, withIntermediateDirectories: true)
        try Data().write(to: bundleURL.appendingPathComponent("coremldata.bin"))
        try Data([0x02]).write(to: bundleURL.appendingPathComponent("model.mil"))

        XCTAssertFalse(
            ModelManager.shared.isValidCoreMLBundle(at: bundleURL),
            "A zero-byte required file must fail validation (bug 4)"
        )
    }

    func testNonexistentPathFailsValidation() {
        let missingURL = tempDir.appendingPathComponent("does-not-exist.mlmodelc")
        XCTAssertFalse(ModelManager.shared.isValidCoreMLBundle(at: missingURL))
    }

    func testRegularFileAtBundlePathFailsValidation() throws {
        // Guards against a plain file masquerading as a bundle directory.
        let fileURL = tempDir.appendingPathComponent("not-a-directory.mlmodelc")
        try Data([0x01]).write(to: fileURL)

        XCTAssertFalse(ModelManager.shared.isValidCoreMLBundle(at: fileURL))
    }

    // MARK: - includeCoreML gating: downloadModel(model:includeCoreML:)
    //
    // These only exercise the guard's early-return path (both needsMainModel
    // and needsCoreML false) — the actual network fetch is not unit-testable
    // without mocking URLSession, and the acceleration policy explicitly
    // forbids real downloads during verification. `includeCoreML` gating
    // itself is a pure precondition check, so it's fully covered without ever
    // reaching `downloadFile`.

    func testIncludeCoreMLFalseSkipsCoreMLFetchWhenMainModelAlreadyDownloaded() async throws {
        try writeMainModelFile(for: .largeV3Turbo)

        try await ModelManager.shared.downloadModel(model: .largeV3Turbo, includeCoreML: false)

        XCTAssertFalse(
            ModelManager.shared.isCoreMLModelDownloaded(model: .largeV3Turbo),
            "includeCoreML: false must skip the encoder even though largeV3Turbo supports one and it's missing"
        )
        XCTAssertFalse(ModelManager.shared.isDownloading, "Early-return path must not leave isDownloading stuck true")
    }

    func testIncludeCoreMLTrueIsANoOpWhenModelDoesNotSupportCoreML() async throws {
        try writeMainModelFile(for: .smallQ5)

        // Must return immediately without attempting a network fetch: smallQ5
        // has no CoreML variant, so needsCoreMLDownload is false regardless of
        // includeCoreML (mirrors ModelManager.needsCoreMLDownload's own guard).
        try await ModelManager.shared.downloadModel(model: .smallQ5, includeCoreML: true)

        XCTAssertFalse(ModelManager.shared.isCoreMLModelDownloaded(model: .smallQ5))
    }

    func testDownloadIsANoOpWhenEverythingAlreadyOnDisk() async throws {
        try writeMainModelFile(for: .largeV3Turbo)
        try writeValidBundle(at: ModelManager.shared.coreMLModelURL(for: .largeV3Turbo))

        // Both needsMainModel and needsCoreML are false here — must return
        // without touching the network, regardless of includeCoreML.
        try await ModelManager.shared.downloadModel(model: .largeV3Turbo, includeCoreML: true)

        XCTAssertTrue(ModelManager.shared.isModelDownloaded(model: .largeV3Turbo))
        XCTAssertTrue(ModelManager.shared.isCoreMLModelDownloaded(model: .largeV3Turbo))
    }

    // MARK: - Defect 3 (code review): deleteModel must not leave filesystem garbage

    /// Mirrors TranscriptionService.shadowModelURL's exact layout: same
    /// filename as the real model, one directory below it, under
    /// AccelerationPolicyResolver.metalOnlyShadowDirectoryName.
    private func writeShadowSymlink(for model: TranscriptionModel) throws {
        let shadowDir = tempDir
            .appendingPathComponent(AccelerationPolicyResolver.metalOnlyShadowDirectoryName, isDirectory: true)
        try fm.createDirectory(at: shadowDir, withIntermediateDirectories: true)
        let target = shadowDir.appendingPathComponent(model.fileName)
        try fm.createSymbolicLink(atPath: target.path, withDestinationPath: "../" + model.fileName)
    }

    func testDeleteModelRemovesItsMetalOnlyShadowSymlink() throws {
        try writeMainModelFile(for: .largeV3Turbo)
        try writeShadowSymlink(for: .largeV3Turbo)

        let shadowPath = tempDir
            .appendingPathComponent(AccelerationPolicyResolver.metalOnlyShadowDirectoryName)
            .appendingPathComponent(TranscriptionModel.largeV3Turbo.fileName)
        XCTAssertTrue(fm.fileExists(atPath: shadowPath.path), "Precondition: shadow symlink must exist before delete")

        try ModelManager.shared.deleteModel(model: .largeV3Turbo)

        XCTAssertFalse(
            fm.fileExists(atPath: shadowPath.path),
            "deleteModel must remove the dangling Metal-only shadow symlink along with the model (defect 3.1)"
        )
    }

    func testDeleteModelWithoutShadowSymlinkDoesNotThrow() throws {
        // No shadow dir at all for this model (e.g. it was never mode-switched
        // to Metal-only) — deletion must still succeed.
        try writeMainModelFile(for: .largeV3Turbo)

        XCTAssertNoThrow(try ModelManager.shared.deleteModel(model: .largeV3Turbo))
    }

    func testDeleteModelDoesNotRemoveNonSymlinkAtShadowPath() throws {
        // Defensive case: something other than a symlink occupying the shadow
        // path (should never happen in practice — nothing else writes there)
        // must be left alone rather than guessed at and deleted.
        try writeMainModelFile(for: .largeV3Turbo)
        let shadowDir = tempDir
            .appendingPathComponent(AccelerationPolicyResolver.metalOnlyShadowDirectoryName, isDirectory: true)
        try fm.createDirectory(at: shadowDir, withIntermediateDirectories: true)
        let stray = shadowDir.appendingPathComponent(TranscriptionModel.largeV3Turbo.fileName)
        try Data([0x01]).write(to: stray)

        try ModelManager.shared.deleteModel(model: .largeV3Turbo)

        XCTAssertTrue(fm.fileExists(atPath: stray.path), "A non-symlink at the shadow path must not be touched")
    }

    func testCleanUpOrphanedScratchDirectoriesRemovesInstallScratchDirs() throws {
        let installDir = tempDir.appendingPathComponent(".install-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: installDir, withIntermediateDirectories: true)
        try Data([0x01]).write(to: installDir.appendingPathComponent("leftover"))

        ModelManager.shared.cleanUpOrphanedScratchDirectories()

        XCTAssertFalse(
            fm.fileExists(atPath: installDir.path),
            "A leftover .install-* scratch dir from a crashed CoreML unzip must be swept on startup (defect 3.2)"
        )
    }

    func testCleanUpOrphanedScratchDirectoriesRemovesShadowScratchSymlinks() throws {
        let shadowDir = tempDir
            .appendingPathComponent(AccelerationPolicyResolver.metalOnlyShadowDirectoryName, isDirectory: true)
        try fm.createDirectory(at: shadowDir, withIntermediateDirectories: true)
        let strayTemp = shadowDir.appendingPathComponent(".shadow-\(UUID().uuidString)")
        try fm.createSymbolicLink(atPath: strayTemp.path, withDestinationPath: "../ggml-tiny-q5_1.bin")

        ModelManager.shared.cleanUpOrphanedScratchDirectories()

        XCTAssertFalse(
            fm.fileExists(atPath: strayTemp.path),
            "A leftover .shadow-* temp symlink from a crashed shadow-path install must be swept on startup (defect 3.2)"
        )
    }

    func testCleanUpOrphanedScratchDirectoriesLeavesRealShadowSymlinksAlone() throws {
        try writeMainModelFile(for: .largeV3Turbo)
        try writeShadowSymlink(for: .largeV3Turbo)
        let realShadowPath = tempDir
            .appendingPathComponent(AccelerationPolicyResolver.metalOnlyShadowDirectoryName)
            .appendingPathComponent(TranscriptionModel.largeV3Turbo.fileName)

        ModelManager.shared.cleanUpOrphanedScratchDirectories()

        XCTAssertTrue(
            fm.fileExists(atPath: realShadowPath.path),
            "The sweep must only remove .install-*/.shadow-* scratch names, never a real (non-dotted-temp) shadow symlink"
        )
    }

    func testCleanUpOrphanedScratchDirectoriesIsANoOpOnCleanDirectory() {
        // Must not throw or crash when there's nothing to sweep (the common
        // case on every normal launch).
        ModelManager.shared.cleanUpOrphanedScratchDirectories()
    }
}
