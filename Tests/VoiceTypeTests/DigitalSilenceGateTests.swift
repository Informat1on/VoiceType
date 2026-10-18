import Foundation
import XCTest
@testable import VoiceType

// docs/plans/silence-gate.md T4. All assertions go through
// DigitalSilenceGate.evaluate(_:) — the gate's only public API.
final class DigitalSilenceGateTests: XCTestCase {

    func testAllZerosIsDigitalSilence() {
        let samples = [Float](repeating: 0, count: 8000)
        XCTAssertTrue(DigitalSilenceGate.evaluate(samples).isDigitalSilence)
    }

    func testEmptyArrayIsNotDigitalSilence() {
        XCTAssertFalse(DigitalSilenceGate.evaluate([]).isDigitalSilence)
    }

    func testAllNaNIsNotDigitalSilence() {
        let samples = [Float](repeating: .nan, count: 100)
        XCTAssertFalse(DigitalSilenceGate.evaluate(samples).isDigitalSilence)
    }

    func testPositiveInfinityIsNotDigitalSilence() {
        let samples = [Float](repeating: .infinity, count: 100)
        XCTAssertFalse(DigitalSilenceGate.evaluate(samples).isDigitalSilence)
    }

    func testNegativeInfinityIsNotDigitalSilence() {
        let samples = [Float](repeating: -.infinity, count: 100)
        XCTAssertFalse(DigitalSilenceGate.evaluate(samples).isDigitalSilence)
    }

    func testMixOfFiniteAndNaNIsNotDigitalSilence() {
        var samples = [Float](repeating: 0, count: 100)
        samples[50] = .nan
        XCTAssertFalse(DigitalSilenceGate.evaluate(samples).isDigitalSilence)
    }

    func testQuietestRealSpeechRMSIsNotDigitalSilence() {
        // Sine wave with RMS = 0.0104 (amplitude = 0.0104 * sqrt(2)) — the
        // quietest real speech on record (docs/plans/shadow-vad.md §8).
        let sampleRate = 16000
        let amplitude = Float(0.0104 * 2.0.squareRoot())
        let frequency: Float = 220
        var samples = [Float](repeating: 0, count: sampleRate)
        for i in 0..<sampleRate {
            let t = Float(i) / Float(sampleRate)
            samples[i] = amplitude * sin(2 * Float.pi * frequency * t)
        }
        let decision = DigitalSilenceGate.evaluate(samples)
        XCTAssertFalse(decision.isDigitalSilence)
        XCTAssertEqual(decision.rms, 0.0104, accuracy: 0.001)
    }

    func testNoiseFloorRMSIsDigitalSilence() {
        // Alternating +-0.00002 -> RMS == 0.00002, far below the threshold.
        var samples = [Float](repeating: 0, count: 16000)
        for i in 0..<samples.count {
            samples[i] = i.isMultiple(of: 2) ? 0.00002 : -0.00002
        }
        XCTAssertTrue(DigitalSilenceGate.evaluate(samples).isDigitalSilence)
    }

    func testThresholdBoundaryIsExclusive() {
        let c = Float(0.002)
        let samples = [Float](repeating: c, count: 1000)
        let decision = DigitalSilenceGate.evaluate(samples)
        // The constant array's own rms is compared against rmsThreshold —
        // no claim that rms == 0.002 exactly (float/double rounding).
        XCTAssertEqual(decision.isDigitalSilence, decision.rms < DigitalSilenceGate.rmsThreshold)
    }

    func testJustBelowThresholdIsDigitalSilence() {
        let samples = [Float](repeating: Float(0.0019), count: 1000)
        XCTAssertTrue(DigitalSilenceGate.evaluate(samples).isDigitalSilence)
    }

    func testJustAboveThresholdIsNotDigitalSilence() {
        let samples = [Float](repeating: Float(0.0021), count: 1000)
        XCTAssertFalse(DigitalSilenceGate.evaluate(samples).isDigitalSilence)
    }

    func testDecisionRMSMatchesConstantSample() {
        let c = Float(0.0015)
        let samples = [Float](repeating: c, count: 500)
        let decision = DigitalSilenceGate.evaluate(samples)
        XCTAssertEqual(decision.rms, abs(Double(c)), accuracy: 1e-9)
    }

    func testFifteenMinutesOfZerosIsDigitalSilenceWithoutTimeout() {
        let samples = [Float](repeating: 0, count: 14_400_000)
        XCTAssertTrue(DigitalSilenceGate.evaluate(samples).isDigitalSilence)
    }
}
