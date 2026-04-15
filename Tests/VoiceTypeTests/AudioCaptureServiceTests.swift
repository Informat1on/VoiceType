import XCTest
import AVFoundation
@testable import VoiceType

final class AudioCaptureServiceTests: XCTestCase {
    func testRequiresConversionForInt16InputEvenAtTargetRate() {
        let inputFormat = AVAudioFormat(
            commonFormat: .pcmFormatInt16,
            sampleRate: 16000,
            channels: 1,
            interleaved: false
        )!

        XCTAssertTrue(AudioCaptureService.requiresConversion(from: inputFormat))
    }

    func testDoesNotRequireConversionForTargetFloatFormat() {
        let inputFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: 16000,
            channels: 1,
            interleaved: false
        )!

        XCTAssertFalse(AudioCaptureService.requiresConversion(from: inputFormat))
    }

    func testNormalizedSamplesSupportInt16Buffers() {
        let format = AVAudioFormat(
            commonFormat: .pcmFormatInt16,
            sampleRate: 16000,
            channels: 1,
            interleaved: false
        )!
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 3)!
        buffer.frameLength = 3
        buffer.int16ChannelData![0][0] = 0
        buffer.int16ChannelData![0][1] = Int16.max / 2
        buffer.int16ChannelData![0][2] = Int16.max

        let samples = AudioCaptureService.normalizedSamples(from: buffer)

        XCTAssertEqual(samples?.count, 3)
        XCTAssertEqual(samples?[0] ?? -1, 0, accuracy: 0.0001)
        XCTAssertEqual(samples?[1] ?? -1, 0.5, accuracy: 0.05)
        XCTAssertEqual(samples?[2] ?? -1, 1.0, accuracy: 0.0001)
    }

    func testUsableInputFormatRequiresPositiveRateAndChannels() {
        let format = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: 16000,
            channels: 1,
            interleaved: false
        )!

        XCTAssertTrue(AudioCaptureService.isUsableInputFormat(format))
    }
}
