import XCTest
@testable import VoiceType

/// T2 (docs/plans/pre-release-wave.md §3): localizes the ggml atexit
/// `GGML_ASSERT([rsets->data count] == 0)` crash (ggml-metal-device.m:622,
/// SwiftWhisper fork) to whether the native Whisper context is actually
/// deallocated once `TranscriptionService.shutdown()` releases `whisper`.
///
/// The bare-SwiftWhisper regression test (`WhisperContextReleaseTests` in the
/// fork's own test target) already proved that a single
/// create→transcribe→release cycle of the raw `Whisper` class deallocates
/// cleanly. This test instead exercises the full `TranscriptionService` /
/// `NativeAbortSignal` / `runNative` machinery — including a LOOP of several
/// transcriptions over one loaded model, matching the shape
/// `ReplayHarnessTests` actually reproduced the crash with (a single
/// transcription was never enough to show it) — to catch a leak that only
/// shows up through `activeRun`, the `runNative` race timers, or warm-up.
///
/// Needs a real whisper.cpp model already on disk under ModelManager's Models
/// directory (same requirement `ReplayHarnessTests` has). Skips rather than
/// downloading one: the repo's tests never trigger real network downloads
/// during verification (see `ModelManagerTests`'s header comment on
/// `downloadModel` coverage).
@MainActor
final class TranscriptionServiceContextReleaseTests: XCTestCase {
    private struct LocalTimeout: Error {}

    /// Prefers `smallQ5` (no CoreML variant on this model — keeps the run on
    /// the plain Metal path, matching the fork-level test) over whichever
    /// larger model happens to be installed.
    private static func installedModelURL() -> URL? {
        let preferenceOrder: [TranscriptionModel] = [
            .smallQ5, .tiny, .base, .small, .medium, .largeV3Turbo, .largeV3TurboQ5
        ]
        for model in preferenceOrder {
            let url = ModelManager.shared.modelURL(for: model)
            if FileManager.default.fileExists(atPath: url.path) {
                return url
            }
        }
        return nil
    }

    func testWhisperContextIsReleasedAfterLoadTranscribeLoopShutdown() async throws {
        guard let modelURL = Self.installedModelURL() else {
            throw XCTSkip("No installed whisper.cpp model found under ModelManager's Models directory")
        }

        var service: TranscriptionService? = TranscriptionService()
        // `model: nil`: an arbitrary path carries no TranscriptionModel case,
        // same as ReplayHarnessTests' VOICETYPE_REPLAY_MODEL override — keeps
        // this test out of the CoreML/acceleration-policy resolution entirely.
        try await service?.loadModel(at: modelURL, language: .auto, model: nil)

        // Let warm-up's own native run retire before measuring, so
        // `service.whisper` reflects a settled state, not a mid-warm-up one.
        let warmUpDeadline = ContinuousClock.now.advanced(by: .seconds(60))
        while service?.modelStatus == .warming {
            guard ContinuousClock.now < warmUpDeadline else {
                throw LocalTimeout()
            }
            try? await Task.sleep(for: .milliseconds(50))
        }

        weak var weakWhisper = service?.whisper
        XCTAssertNotNil(weakWhisper, "Precondition: TranscriptionService.whisper must be set after loadModel()")

        // Same 500ms-silence buffer performWarmUp() itself pushes through
        // whisper — cheap, deterministic, and exercises the exact same
        // runNative/whisper.transcribe path a real transcription takes.
        // Looped rather than called once: the crash this localizes was only
        // ever observed after MULTIPLE real transcriptions over one loaded
        // model, not a lone call.
        let silenceBuffer = [Float](repeating: 0, count: 8_000)
        for _ in 0..<5 {
            _ = try await service?.transcribe(audio: silenceBuffer, language: .auto)
        }

        let shutdownSucceeded = await service?.shutdown()
        XCTAssertEqual(
            shutdownSucceeded,
            true,
            "shutdown() must report success (context released cleanly) — false means a transcription "
                + "or abandoned run was still outstanding past the drain deadline"
        )

        service = nil

        XCTAssertNil(
            weakWhisper,
            "The native Whisper context must be deallocated once TranscriptionService.shutdown() "
                + "releases it — a non-nil weak reference here is exactly what leaves whisper_free() "
                + "uncalled and the Metal device holding buffers at atexit "
                + "(ggml-metal-device.m:622 GGML_ASSERT([rsets->data count] == 0))."
        )
    }

    // MARK: - race(): the actual leak site (NativeAbortSignal.swift)
    //
    // The test above proves the end-to-end symptom against a real model; this
    // one isolates the exact mechanism without needing whisper.cpp at all.
    // `runNative`'s `onTimeout` closure captures `whisper` strongly (needed so
    // it can call `abandonRun(token:whisper:reason:)` if the timer actually
    // wins). Before the fix, the timer's `Task` was never cancelled when
    // `operation` won instead, so that closure — and whatever it captured —
    // stayed alive for the FULL `timeout` (up to 30s in production) even
    // though it could never fire again. `race()` is generic, so a plain
    // reference-counted `Marker` stands in for `whisper` here.

    /// Thread-safe flag for asserting `onTimeout` did or didn't run.
    private final class FlagBox: @unchecked Sendable {
        private let lock = NSLock()
        private var flag = false
        func set() { lock.lock(); flag = true; lock.unlock() }
        var isSet: Bool { lock.lock(); defer { lock.unlock() }; return flag }
    }

    private final class Marker {}

    func testRaceCancelsTimeoutTaskWhenOperationWinsSoOnTimeoutCaptureIsReleasedPromptly() async throws {
        weak var weakMarker: Marker?
        let onTimeoutCalled = FlagBox()

        // Nested so `marker`'s own local binding goes out of scope the moment
        // this returns — after that, the ONLY thing that could still keep it
        // alive is a not-yet-cancelled timer task's `onTimeout` closure.
        func runFastOperation() async throws {
            let marker = Marker()
            weakMarker = marker

            let result = try await TranscriptionService.race(
                timeout: 30, // deliberately large: if the timer isn't cancelled, `marker` would linger up to 30s
                operation: { "fast" },
                onTimeout: {
                    onTimeoutCalled.set()
                    withExtendedLifetime(marker) {} // mirrors runNative's onTimeout capturing `whisper`
                }
            )
            XCTAssertEqual(result, "fast")
        }

        try await runFastOperation()

        // Bounded wait for the cancelled timer task to actually retire
        // (cancellation propagates asynchronously) — NOT the 30s timeout.
        let deadline = ContinuousClock.now.advanced(by: .seconds(2))
        while weakMarker != nil && ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(10))
        }

        XCTAssertNil(
            weakMarker,
            "race() must cancel the timeout task once operation wins, so onTimeout's captured "
                + "reference (whisper, in the real runNative caller) is released promptly instead "
                + "of lingering for the full timeout"
        )
        XCTAssertFalse(onTimeoutCalled.isSet, "onTimeout must never fire when operation wins")
    }
}
