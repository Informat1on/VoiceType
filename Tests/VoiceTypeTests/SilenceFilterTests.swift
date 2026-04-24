import XCTest
@testable import VoiceType

/// Regression tests for the silence/hallucination filters that prevent
/// Whisper from typing garbage when the user holds the hotkey without
/// speaking. AppDelegate.samplesAreSilent + isHallucination are pure
/// `static` helpers so they test without any AppKit bootstrap.
final class SilenceFilterTests: XCTestCase {

    // MARK: - samplesAreSilent

    func testEmptySamplesAreSilent() {
        XCTAssertTrue(AppDelegate.samplesAreSilent([]))
    }

    func testAllZerosAreSilent() {
        let samples = Array(repeating: Float(0), count: 16_000)
        XCTAssertTrue(AppDelegate.samplesAreSilent(samples))
    }

    func testRoomNoiseAtRMS002IsSilent() {
        // Typical laptop mic ambient: white-ish noise at ~0.002 peak.
        let samples = (0..<16_000).map { _ in Float.random(in: -0.003...0.003) }
        XCTAssertTrue(AppDelegate.samplesAreSilent(samples), "Quiet room noise must fail silence gate")
    }

    func testConversationalSpeechIsNotSilent() {
        // Simulated speech: peaks up to 0.15, RMS around 0.04.
        var samples: [Float] = []
        for i in 0..<16_000 {
            let envelope = Float(sin(Double(i) * 0.001))
            samples.append(envelope * 0.15)
        }
        XCTAssertFalse(AppDelegate.samplesAreSilent(samples), "Speech-amplitude audio must pass the gate")
    }

    func testSingleLoudSpikeButMostlySilentIsSilent() {
        // One cough spike at 0.8 but RMS still tiny → silent.
        var samples = Array(repeating: Float(0.001), count: 16_000)
        samples[5_000] = 0.8
        // Peak > 0.03 BUT rms < 0.008 → gate returns true (silent).
        XCTAssertTrue(AppDelegate.samplesAreSilent(samples), "RMS gate must catch isolated spikes in otherwise silent audio")
    }

    // MARK: - isHallucination

    func testEmptyTextIsHallucination() {
        XCTAssertTrue(AppDelegate.isHallucination(""))
    }

    func testWhitespaceOnlyIsHallucination() {
        XCTAssertTrue(AppDelegate.isHallucination("   "))
    }

    func testSingleDotIsHallucination() {
        XCTAssertTrue(AppDelegate.isHallucination("."))
    }

    func testThanksForWatchingIsHallucination() {
        XCTAssertTrue(AppDelegate.isHallucination("Thanks for watching!"))
        XCTAssertTrue(AppDelegate.isHallucination("thanks for watching"))
        XCTAssertTrue(AppDelegate.isHallucination("  Thank you for watching  "))
    }

    func testRussianHallucinationsCaught() {
        XCTAssertTrue(AppDelegate.isHallucination("Продолжение следует..."))
        XCTAssertTrue(AppDelegate.isHallucination("Спасибо за просмотр"))
        XCTAssertTrue(AppDelegate.isHallucination("Подписывайтесь"))
    }

    func testMusicMarkersAreHallucination() {
        XCTAssertTrue(AppDelegate.isHallucination("[Music]"))
        XCTAssertTrue(AppDelegate.isHallucination("♪"))
        XCTAssertTrue(AppDelegate.isHallucination("[музыка]"))
    }

    func testRealSentenceIsNotHallucination() {
        XCTAssertFalse(AppDelegate.isHallucination("Привет, как дела?"))
        XCTAssertFalse(AppDelegate.isHallucination("Hello, this is a real sentence."))
        XCTAssertFalse(AppDelegate.isHallucination("let me add this feature to the backend"))
    }

    func testShortButValidWordIsNotHallucination() {
        // "yes" and "ok" — 2-3 chars might be real one-word replies.
        // Our filter says <3 chars is junk; "yes" (3 chars) barely passes.
        XCTAssertFalse(AppDelegate.isHallucination("yes"))
        // "ok" is 2 chars → filtered as junk (acceptable tradeoff).
        XCTAssertTrue(AppDelegate.isHallucination("ok"))
    }
}
