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

    func testTranscriptionModelEnumCount() {
        XCTAssertEqual(TranscriptionModel.allCases.count, 6)
    }

    func testCaseOrderingPlacesTurboLast() {
        XCTAssertEqual(TranscriptionModel.allCases.last, .largeV3Turbo)
    }

    // MARK: - Engine compatibility (C2 fix)

    func testLargeV3TurboIsNotCompatibleWithCurrentEngine() {
        XCTAssertFalse(
            TranscriptionModel.largeV3Turbo.isCompatibleWithCurrentEngine,
            "largeV3Turbo requires whisper.cpp >= v1.7.0; SwiftWhisper bundles v1.4.2"
        )
    }

    func testAllOtherModelsAreCompatibleWithCurrentEngine() {
        let incompatible: Set<TranscriptionModel> = [.largeV3Turbo]
        for model in TranscriptionModel.allCases where !incompatible.contains(model) {
            XCTAssertTrue(
                model.isCompatibleWithCurrentEngine,
                "\(model.rawValue) should be compatible with the current engine"
            )
        }
    }
}
