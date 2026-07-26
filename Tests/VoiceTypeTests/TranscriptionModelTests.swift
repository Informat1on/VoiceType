import XCTest
@testable import VoiceType

final class TranscriptionModelTests: XCTestCase {

    func testLargeV3TurboRawValueAndDownloadURL() {
        let model = TranscriptionModel.largeV3Turbo
        XCTAssertEqual(model.rawValue, "large-v3-turbo")
        XCTAssertEqual(model.fileName, "ggml-large-v3-turbo.bin")
        XCTAssertEqual(
            model.downloadURL,
            "https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-large-v3-turbo.bin"
        )
        // Both the .bin URL above and the CoreML zip URL below derive from the same
        // rawValue, but checking each independently catches a future override of
        // either property.
        XCTAssertEqual(
            model.coreMLZipFileName,
            "ggml-large-v3-turbo-encoder.mlmodelc.zip"
        )
        XCTAssertEqual(
            model.coreMLDownloadURL,
            "https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-large-v3-turbo-encoder.mlmodelc.zip"
        )
    }

    func testLargeV3TurboHasCoreMLSupport() {
        XCTAssertTrue(TranscriptionModel.largeV3Turbo.hasCoreMLSupport)
    }

    func testLargeV3TurboDisplayName() {
        XCTAssertEqual(
            TranscriptionModel.largeV3Turbo.displayName,
            "Large v3 Turbo (Highest quality, fast)"
        )
    }

    func testLargeV3TurboQ5RawValueAndDownloadURL() {
        let model = TranscriptionModel.largeV3TurboQ5
        XCTAssertEqual(model.rawValue, "large-v3-turbo-q5_0")
        XCTAssertEqual(model.fileName, "ggml-large-v3-turbo-q5_0.bin")
        XCTAssertEqual(
            model.downloadURL,
            "https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-large-v3-turbo-q5_0.bin"
        )
        // Q5 shares the fp16 CoreML encoder with the full Turbo model.
        XCTAssertEqual(model.coreMLZipFileName, "ggml-large-v3-turbo-encoder.mlmodelc.zip")
        XCTAssertEqual(
            model.coreMLDownloadURL,
            "https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-large-v3-turbo-encoder.mlmodelc.zip"
        )
    }

    func testLargeV3TurboQ5DisplayName() {
        XCTAssertEqual(
            TranscriptionModel.largeV3TurboQ5.displayName,
            "Large v3 Turbo Q5 (Highest quality, fast, compact)"
        )
    }

    func testLargeV3TurboQ5HasCoreMLSupport() {
        XCTAssertTrue(TranscriptionModel.largeV3TurboQ5.hasCoreMLSupport)
    }

    func testTranscriptionModelEnumCount() {
        XCTAssertEqual(TranscriptionModel.allCases.count, 7)
    }

    func testCaseOrderingPlacesTurboQ5Last() {
        XCTAssertEqual(TranscriptionModel.allCases.last, .largeV3TurboQ5)
    }

    // MARK: - Engine compatibility
    // Forked SwiftWhisper bundles whisper.cpp v1.7.5 — all models compatible.

    func testAllModelsAreCompatibleWithCurrentEngine() {
        for model in TranscriptionModel.allCases {
            XCTAssertTrue(
                model.isCompatibleWithCurrentEngine,
                "\(model.rawValue) should be compatible with whisper.cpp v1.7.5"
            )
        }
    }

    // MARK: - Defect 2 (code review): coreMLExplanation must not contradict SettingsView's GPU claim

    /// small-q5_1 has no CoreML encoder, but whisper.cpp still falls through to
    /// Metal for its encoder (WHISPER_COREML_ALLOW_FALLBACK) — it is not
    /// CPU-bound. The explanation text used to say "(CPU only)" while
    /// SettingsView's footnote said "always runs on the GPU" right next to it;
    /// this guards against that contradiction resurfacing.
    func testSmallQ5ExplanationDoesNotClaimCPUOnly() {
        let explanation = TranscriptionModel.smallQ5.coreMLExplanation
        XCTAssertNotNil(explanation)
        XCTAssertFalse(
            explanation?.localizedCaseInsensitiveContains("CPU only") ?? true,
            "coreMLExplanation must not claim CPU-only — small-q5_1 runs on the GPU via Metal (code review)"
        )
        XCTAssertTrue(
            explanation?.localizedCaseInsensitiveContains("GPU") ?? false,
            "coreMLExplanation must state the true outcome: this model runs on the GPU"
        )
    }

    /// Regression guard: every other model has no CoreML explanation at all
    /// (they all ship a CoreML variant), so this text path only ever applies
    /// to small-q5_1.
    func testOnlySmallQ5HasACoreMLExplanation() {
        for model in TranscriptionModel.allCases where model != .smallQ5 {
            XCTAssertNil(
                model.coreMLExplanation,
                "\(model.rawValue) ships a CoreML variant and should have no explanation text"
            )
        }
    }
}
