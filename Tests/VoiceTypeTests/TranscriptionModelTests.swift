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
}
