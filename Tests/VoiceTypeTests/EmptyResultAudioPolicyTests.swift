// EmptyResultAudioPolicyTests.swift — VoiceType
//
// Unit tests for EmptyResultAudioPolicy.decide (C1) and EmptyResultAudioHandler
// (C5). docs/plans/empty-result-audio.md §5 DoD.

import XCTest
@testable import VoiceType

@MainActor
final class EmptyResultAudioPolicyTests: XCTestCase {

    // MARK: - C1: EmptyResultAudioPolicy.decide

    // MARK: audioPath == nil → .nothing, regardless of every other input

    func testNilAudioPathAlwaysYieldsNothing() {
        XCTAssertEqual(
            EmptyResultAudioPolicy.decide(isDigitalSilence: false, wasInterrupted: false, audioPath: nil, audioDurationSeconds: 5.0),
            .nothing
        )
        XCTAssertEqual(
            EmptyResultAudioPolicy.decide(isDigitalSilence: true, wasInterrupted: false, audioPath: nil, audioDurationSeconds: nil),
            .nothing
        )
        XCTAssertEqual(
            EmptyResultAudioPolicy.decide(isDigitalSilence: false, wasInterrupted: true, audioPath: nil, audioDurationSeconds: 5.0),
            .nothing,
            "wasInterrupted must not override a missing audioPath — there's nothing to keep or retry"
        )
    }

    // MARK: wasInterrupted → .recordFailedEntry, priority over silence and duration

    func testInterruptedWithDigitalSilenceRecordsFailedEntry() {
        XCTAssertEqual(
            EmptyResultAudioPolicy.decide(isDigitalSilence: true, wasInterrupted: true, audioPath: "a.caf", audioDurationSeconds: 5.0),
            .recordFailedEntry
        )
    }

    func testInterruptedWithShortDurationRecordsFailedEntry() {
        XCTAssertEqual(
            EmptyResultAudioPolicy.decide(isDigitalSilence: false, wasInterrupted: true, audioPath: "a.caf", audioDurationSeconds: 0.3),
            .recordFailedEntry
        )
    }

    func testInterruptedWithNilDurationRecordsFailedEntry() {
        XCTAssertEqual(
            EmptyResultAudioPolicy.decide(isDigitalSilence: false, wasInterrupted: true, audioPath: "a.caf", audioDurationSeconds: nil),
            .recordFailedEntry
        )
    }

    // MARK: digital silence (not interrupted) → .discardAudio

    func testDigitalSilenceDiscardsAudio() {
        XCTAssertEqual(
            EmptyResultAudioPolicy.decide(isDigitalSilence: true, wasInterrupted: false, audioPath: "a.caf", audioDurationSeconds: 10.0),
            .discardAudio,
            "Digital silence discards even a long recording — RMS below threshold means no speech"
        )
    }

    // MARK: duration threshold — exactly 1.0s and 0.999s

    func testDurationExactlyAtThresholdRecordsFailedEntry() {
        XCTAssertEqual(
            EmptyResultAudioPolicy.decide(isDigitalSilence: false, wasInterrupted: false, audioPath: "a.caf", audioDurationSeconds: 1.0),
            .recordFailedEntry,
            "Exactly minimumRetryableSeconds must qualify (>=, not >)"
        )
    }

    func testDurationJustBelowThresholdDiscardsAudio() {
        XCTAssertEqual(
            EmptyResultAudioPolicy.decide(isDigitalSilence: false, wasInterrupted: false, audioPath: "a.caf", audioDurationSeconds: 0.999),
            .discardAudio
        )
    }

    // MARK: nil / non-finite duration → .discardAudio

    func testNilDurationDiscardsAudio() {
        XCTAssertEqual(
            EmptyResultAudioPolicy.decide(isDigitalSilence: false, wasInterrupted: false, audioPath: "a.caf", audioDurationSeconds: nil),
            .discardAudio
        )
    }

    func testNaNDurationDiscardsAudio() {
        XCTAssertEqual(
            EmptyResultAudioPolicy.decide(isDigitalSilence: false, wasInterrupted: false, audioPath: "a.caf", audioDurationSeconds: .nan),
            .discardAudio
        )
    }

    func testInfiniteDurationDiscardsAudio() {
        XCTAssertEqual(
            EmptyResultAudioPolicy.decide(
                isDigitalSilence: false, wasInterrupted: false, audioPath: "a.caf", audioDurationSeconds: .infinity
            ),
            .discardAudio
        )
    }

    // MARK: - C5: EmptyResultAudioHandler

    /// Small struct instead of a 3-member tuple (swiftlint large_tuple).
    private struct Fixture {
        let handler: EmptyResultAudioHandler
        let store: HistoryStore
        let audioDir: URL
    }

    private func makeHandler() throws -> Fixture {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }

        let audioDir = dir.appendingPathComponent("audio")
        try FileManager.default.createDirectory(at: audioDir, withIntermediateDirectories: true)

        let storeURL = dir.appendingPathComponent("history.jsonl")
        let store = HistoryStore.test(storeURL: storeURL, audioDirectory: audioDir, errorLogger: makeTestErrorLogger(in: dir))
        let recorder = HistoryRecorder(store: store)
        let handler = EmptyResultAudioHandler(store: store, recorder: recorder)
        return Fixture(handler: handler, store: store, audioDir: audioDir)
    }

    private func makeFailure(audioDuration: Double?) -> (String) -> HistoryRecorder.FailedTranscription {
        { path in
            HistoryRecorder.FailedTranscription(
                targetAppName: "TestApp",
                targetAppBundleID: "com.test",
                language: "en",
                audioPath: path,
                model: "small.en-q5_1",
                audioDurationSeconds: audioDuration,
                reason: "empty"
            )
        }
    }

    func testDigitalSilenceDeletesFileAndRecordsNoEntry() throws {
        let fixture = try makeHandler()
        let handler = fixture.handler
        let store = fixture.store
        let audioDir = fixture.audioDir
        let audioURL = audioDir.appendingPathComponent("silent.caf")
        try Data("audio".utf8).write(to: audioURL)

        var failureCalled = false
        let action = handler.handle(
            reason: .digitalSilence,
            wasInterrupted: false,
            audioPath: "silent.caf",
            audioDurationSeconds: 5.0
        ) { path in
            failureCalled = true
            return self.makeFailure(audioDuration: 5.0)(path)
        }

        XCTAssertEqual(action, .discardAudio)
        XCTAssertFalse(failureCalled, "failure closure must not be invoked on .discardAudio")
        XCTAssertFalse(FileManager.default.fileExists(atPath: audioURL.path), "Digital-silence audio must be deleted")
        XCTAssertTrue(store.entries().isEmpty, "No History entry for digital silence")
    }

    func testWhisperEmptyAboveThresholdRecordsFailedEntryAndKeepsFile() throws {
        let fixture = try makeHandler()
        let handler = fixture.handler
        let store = fixture.store
        let audioDir = fixture.audioDir
        let audioURL = audioDir.appendingPathComponent("empty2s.caf")
        try Data("audio".utf8).write(to: audioURL)

        var failureCalled = false
        let action = handler.handle(
            reason: .whisperEmpty,
            wasInterrupted: false,
            audioPath: "empty2s.caf",
            audioDurationSeconds: 2.0
        ) { path in
            failureCalled = true
            return self.makeFailure(audioDuration: 2.0)(path)
        }

        XCTAssertEqual(action, .recordFailedEntry)
        XCTAssertTrue(failureCalled, "failure closure must be invoked on .recordFailedEntry")
        XCTAssertTrue(FileManager.default.fileExists(atPath: audioURL.path), "Audio must be kept for a retryable failed entry")

        let entries = store.entries()
        XCTAssertEqual(entries.count, 1)
        let entry = try XCTUnwrap(entries.first)
        XCTAssertEqual(entry.text, "")
        XCTAssertEqual(entry.status, .failed)
        XCTAssertEqual(entry.failureReason, "empty")
        XCTAssertEqual(entry.audioPath, "empty2s.caf")
    }

    func testWhisperEmptyBelowThresholdDeletesFile() throws {
        let fixture = try makeHandler()
        let handler = fixture.handler
        let store = fixture.store
        let audioDir = fixture.audioDir
        let audioURL = audioDir.appendingPathComponent("short.caf")
        try Data("audio".utf8).write(to: audioURL)

        let action = handler.handle(
            reason: .whisperEmpty,
            wasInterrupted: false,
            audioPath: "short.caf",
            audioDurationSeconds: 0.5
        ) { self.makeFailure(audioDuration: 0.5)($0) }

        XCTAssertEqual(action, .discardAudio)
        XCTAssertFalse(FileManager.default.fileExists(atPath: audioURL.path))
        XCTAssertTrue(store.entries().isEmpty)
    }

    func testInterruptedDigitalSilenceRecordsFailedEntryAndKeepsFile() throws {
        let fixture = try makeHandler()
        let handler = fixture.handler
        let store = fixture.store
        let audioDir = fixture.audioDir
        let audioURL = audioDir.appendingPathComponent("interrupted.caf")
        try Data("audio".utf8).write(to: audioURL)

        let action = handler.handle(
            reason: .digitalSilence,
            wasInterrupted: true,
            audioPath: "interrupted.caf",
            audioDurationSeconds: 0.3
        ) { self.makeFailure(audioDuration: 0.3)($0) }

        XCTAssertEqual(action, .recordFailedEntry)
        XCTAssertTrue(FileManager.default.fileExists(atPath: audioURL.path), "Interrupted audio is never discarded")

        let entries = store.entries()
        XCTAssertEqual(entries.count, 1)
        XCTAssertEqual(entries.first?.status, .failed)
        XCTAssertEqual(entries.first?.failureReason, "empty")
    }

    func testNilAudioPathYieldsNothingAndNeverCallsFailure() throws {
        let fixture = try makeHandler()
        let handler = fixture.handler
        let store = fixture.store

        var failureCalled = false
        let action = handler.handle(
            reason: .whisperEmpty,
            wasInterrupted: true,
            audioPath: nil,
            audioDurationSeconds: 5.0
        ) { path in
            failureCalled = true
            return self.makeFailure(audioDuration: 5.0)(path)
        }

        XCTAssertEqual(action, .nothing)
        XCTAssertFalse(failureCalled, "failure closure must not be invoked on .nothing")
        XCTAssertTrue(store.entries().isEmpty, "No History entry when there's no audio at all")
    }
}
