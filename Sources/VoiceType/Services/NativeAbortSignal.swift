import Foundation
import SwiftWhisper

// MARK: - NativeAbortSignal

/// Thread-safe abort flag read by whisper.cpp's `ggml_abort_callback` from a
/// background compute thread while `whisper_full` is running (D3, "honest ASR
/// timeout"). `TranscriptionService.runNative` installs `abortCallback` as
/// `whisper.params.abort_callback` and passes an unretained pointer to the
/// owning `NativeAbortSignal` as `abort_callback_user_data` immediately before
/// starting each native call.
///
/// Ownership: this class does not keep whisper.cpp from touching a dangling
/// pointer by itself — the caller (`runNative`'s `operation` closure) must
/// hold a strong reference to the signal for as long as the native call may
/// still read `abort_callback_user_data`, i.e. until `whisper.transcribe(...)`
/// actually returns. See the `withExtendedLifetime` calls there.
final class NativeAbortSignal: @unchecked Sendable {
    private let lock = NSLock()
    private var triggered = false

    /// Asks the in-flight native call to abort at its next checkpoint.
    /// Idempotent — safe to call more than once.
    func trigger() {
        lock.lock()
        triggered = true
        lock.unlock()
    }

    var isTriggered: Bool {
        lock.lock()
        defer { lock.unlock() }
        return triggered
    }

    /// Matches `ggml_abort_callback` (`typedef bool (*ggml_abort_callback)(void * data)`,
    /// `ggml.h:706`; installed on `whisper_full_params.abort_callback`,
    /// `whisper.h:574` in the SwiftWhisper fork's vendored headers). ggml polls
    /// this between compute steps and aborts the graph the moment it returns
    /// `true`.
    ///
    /// `data` is whatever raw pointer was installed as `abort_callback_user_data`
    /// — here always an `Unmanaged<NativeAbortSignal>` created with
    /// `.passUnretained(_:)`, so this callback never retains or releases it;
    /// the caller's own strong reference is what keeps the signal alive.
    static let abortCallback: @convention(c) (UnsafeMutableRawPointer?) -> Bool = { data in
        guard let data else { return false }
        let signal = Unmanaged<NativeAbortSignal>.fromOpaque(data).takeUnretainedValue()
        return signal.isTriggered
    }
}

// MARK: - NativeCString

/// Owns a `strdup`-allocated C string used as `whisper_full_params.initial_prompt`.
/// `whisper_full` reads this pointer from a background thread for the entire
/// duration of the native call it belongs to, so the buffer must outlive that
/// call. Wrapping it in a class turns that lifetime requirement into an
/// ordinary ARC one: whoever keeps a strong reference to the `NativeCString`
/// (the service's `_initialPrompt` slot, and — while a call is in flight — the
/// closure captured by `TranscriptionService.runNative`) keeps the buffer
/// alive; `deinit` frees it once the last reference drops, instead of any call
/// site calling `free` manually.
final class NativeCString: @unchecked Sendable {
    let pointer: UnsafeMutablePointer<CChar>

    init?(_ text: String) {
        guard let ptr = strdup(text) else { return nil }
        pointer = ptr
    }

    deinit {
        free(pointer)
    }
}

// MARK: - NativeRunToken

/// Bookkeeping for one `whisper_full` call started by
/// `TranscriptionService.runNative`, so an external bounded wait (runNative's
/// own timeout, or transcribe's/shutdown's warm-up wait) can trigger its abort
/// signal and mark it abandoned exactly once. No `TranscriptionService`-private
/// state needed, so it lives here rather than in TranscriptionService.swift.
final class NativeRunToken: @unchecked Sendable {
    let signal = NativeAbortSignal()
    private let lock = NSLock()
    private var returned = false
    private var abandoned = false

    /// Marks that the native call behind this token has actually returned
    /// (`onNativeRunReturned` fired). Idempotent — safe to call more than
    /// once. Called before checking `isAbandoned` so a concurrent
    /// `abandonRun` racing the real return sees this and backs off instead
    /// of marking a run abandoned that's already retired (see
    /// `markAbandonedIfStillRunning`).
    func markReturned() {
        lock.lock()
        returned = true
        lock.unlock()
    }

    /// Atomically transitions this token to abandoned, but only if the
    /// native call hasn't already returned and it isn't already abandoned.
    /// `true` only for the caller that actually performs that transition —
    /// `false` means a full no-op for the caller (an already-returned or
    /// already-abandoned run must not be touched again: no counter change,
    /// no signal trigger, no cancel, no model teardown). This closes the
    /// race where `onTimeout` merely *schedules* `abandonRun` on MainActor
    /// and the native call returns before that scheduled call runs.
    @discardableResult
    func markAbandonedIfStillRunning() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard !returned, !abandoned else { return false }
        abandoned = true
        return true
    }

    var isAbandoned: Bool {
        lock.lock()
        defer { lock.unlock() }
        return abandoned
    }
}

// MARK: - Race helpers

/// Resumes a `CheckedContinuation` at most once, whichever of two racing
/// closures gets there first. Thread-safe (`NSLock`) since `TranscriptionService.race`
/// calls `claim()` from two independent, non-actor-isolated Tasks.
private final class RaceOutcomeBox<T: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var settled = false
    private let continuation: CheckedContinuation<T, Error>

    init(_ continuation: CheckedContinuation<T, Error>) {
        self.continuation = continuation
    }

    /// `true` only for the caller that wins the race — that caller, and only
    /// that caller, must go on to call `resume`.
    @discardableResult
    func claim() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard !settled else { return false }
        settled = true
        return true
    }

    func resume(_ result: Result<T, Error>) {
        switch result {
        case .success(let value): continuation.resume(returning: value)
        case .failure(let error): continuation.resume(throwing: error)
        }
    }
}

// MARK: - D3: native run execution (runNative, abandonRun)
//
// Kept here, in an `extension TranscriptionService`, rather than in
// TranscriptionService.swift, purely to stay under that file's file_length
// budget — this is TranscriptionService's own state (`whisper`, `modelURL`,
// `modelStatus`, `modelLoadGeneration`, `warmUpTask`, `abandonedRunCount`,
// `activeRun`, `_initialPrompt` are `internal`, not `private`, for exactly
// this reason) and used only by `transcribe`/`performWarmUp`/`shutdown` there.
extension TranscriptionService {
    /// Runs one `whisper_full` pass through the shared abort/timeout machinery:
    /// wires a fresh `NativeAbortSignal` into `whisper.params.abort_callback`
    /// then races it against `timeout` (`abandonRun` on expiry) instead of
    /// wedging the caller on a stuck native call forever.
    ///
    /// UAF safety: `whisper`, `promptBox` (what `initial_prompt` points into)
    /// and `token.signal` are captured by `operation` below and stay retained
    /// across the `await whisper.transcribe(...)` suspension on both the
    /// success and throw paths (`withExtendedLifetime`) — so `abandonRun` can
    /// safely replace `self.whisper`/`self._initialPrompt` while this call is
    /// still running on its own thread.
    func runNative(on whisper: Whisper, audio: [Float], timeout: TimeInterval) async throws -> [Segment] {
        let token = NativeRunToken()
        let promptBox = _initialPrompt

        whisper.params.abort_callback = NativeAbortSignal.abortCallback
        whisper.params.abort_callback_user_data = Unmanaged.passUnretained(token.signal).toOpaque()

        activeRun = (token, whisper)
        defer {
            if activeRun?.token === token {
                activeRun = nil
            }
        }

        return try await Self.race(
            timeout: timeout,
            operation: { [weak self] in
                do {
                    let segments = try await whisper.transcribe(audioFrames: audio)
                    await self?.onNativeRunReturned(token, on: whisper)
                    withExtendedLifetime(promptBox) {}
                    withExtendedLifetime(token.signal) {}
                    return segments
                } catch {
                    await self?.onNativeRunReturned(token, on: whisper)
                    withExtendedLifetime(promptBox) {}
                    withExtendedLifetime(token.signal) {}
                    throw error
                }
            },
            onTimeout: { [weak self] in
                Task { @MainActor in
                    self?.abandonRun(token: token, whisper: whisper, reason: "Native run exceeded \(timeout)s timeout")
                }
            }
        )
    }

    /// Fires once the native call behind `token` actually returns, on
    /// MainActor. NOT gated on `self.whisper === whisper` — a newer model may
    /// already be loaded by the time an abandoned run retires.
    func onNativeRunReturned(_ token: NativeRunToken, on whisper: Whisper) {
        token.markReturned()
        if token.isAbandoned {
            abandonedRunCount -= 1
        }
        // Only clear if still targeting THIS run's signal — an overlapping
        // newer run may already have overwritten it.
        let thisSignalPointer = Unmanaged.passUnretained(token.signal).toOpaque()
        if whisper.params.abort_callback_user_data == thisSignalPointer {
            whisper.params.abort_callback = nil
            whisper.params.abort_callback_user_data = nil
        }
    }

    /// Shared "abandon" for a native run past its timeout — used by
    /// `runNative`'s own timeout and the bounded warm-up waits in `transcribe`
    /// and `shutdown`. Idempotent (and a full no-op once the run has already
    /// returned) via `NativeRunToken.markAbandonedIfStillRunning`.
    func abandonRun(token: NativeRunToken, whisper: Whisper, reason: String) {
        guard token.markAbandonedIfStillRunning() else { return }
        abandonedRunCount += 1
        token.signal.trigger()
        // Non-blocking: only arms `cancelCallback` so the background thread
        // reports `.cancelled` once whisper_full actually returns (which the
        // abort_callback above should now make happen promptly). NEVER the
        // async `whisper.cancel()` — it awaits a continuation that only
        // resumes once that SAME call returns, i.e. the hang this avoids.
        try? whisper.cancel(completionHandler: {})
        AppLog.transcription.error("\(reason) — abandoning native run (abandonedRunCount=\(self.abandonedRunCount))")

        guard self.whisper === whisper else { return }
        self.whisper = nil
        self.modelURL = nil
        self.modelStatus = .notLoaded
        modelLoadGeneration &+= 1
        warmUpTask?.cancel()
        warmUpTask = nil
    }

    /// D3: the timeout ceiling actually used for a transcription — never less
    /// than the audio's own duration, so long recordings that used to complete
    /// are not cut short by a fixed base budget.
    nonisolated static func effectiveTimeout(base: TimeInterval, audioSeconds: Double) -> TimeInterval {
        max(base, audioSeconds)
    }

    /// Races `operation` against a `timeout`-second timer. Whichever finishes
    /// first wins; the loser is NOT cancelled or awaited — `operation` keeps
    /// running in the background if the timer wins (that is what makes a
    /// timeout here safe against a native call that will never itself return
    /// promptly — see `runNative`/`abandonRun`). Timeout invokes `onTimeout()`
    /// exactly once, before throwing `TranscriptionError.transcriptionTimeout`;
    /// an `operation` error/result is passed through unchanged.
    nonisolated static func race<T: Sendable>(
        timeout: TimeInterval,
        operation: @escaping @Sendable () async throws -> T,
        onTimeout: @escaping @Sendable () -> Void
    ) async throws -> T {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<T, Error>) in
            let box = RaceOutcomeBox(continuation)

            Task {
                do {
                    let result = try await operation()
                    if box.claim() { box.resume(.success(result)) }
                } catch {
                    if box.claim() { box.resume(.failure(error)) }
                }
            }

            Task {
                let nanoseconds = UInt64((max(0, timeout) * 1_000_000_000).rounded())
                try? await Task.sleep(nanoseconds: nanoseconds)
                if box.claim() {
                    onTimeout()
                    box.resume(.failure(TranscriptionError.transcriptionTimeout))
                }
            }
        }
    }
}
