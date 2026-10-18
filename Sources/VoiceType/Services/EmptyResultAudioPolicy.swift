// EmptyResultAudioPolicy.swift — VoiceType
//
// docs/plans/empty-result-audio.md §3 C1/C5.
//
// Decides the fate of a dictation's saved audio file when the result is
// empty (digital silence, or whisper returned "") — either the interrupted
// flag is set. Split out as a pure decision (EmptyResultAudioPolicy.decide)
// plus a thin, testable side-effecting wrapper (EmptyResultAudioHandler) so
// both can be exercised without AppDelegate or a real NSWindow.

import Foundation

/// Pure decision: what should happen to a dictation's saved audio file (and
/// whether History should gain a failed entry) when the transcription result
/// is empty. See docs/plans/empty-result-audio.md §2 for the behavior table
/// and §3 C1 for the rule order below.
enum EmptyResultAudioPolicy {
    enum Action: Equatable {
        case discardAudio
        case recordFailedEntry
        case nothing
    }

    /// Recordings shorter than this are treated as an accidental hotkey
    /// tap — nothing to retry, and keeping them as failed History entries
    /// would just add noise. docs/plans/empty-result-audio.md §2.
    static let minimumRetryableSeconds: Double = 1.0

    /// Rule order (first match wins), per §3 C1:
    /// 1. No saved audio at all → nothing to do or retry.
    /// 2. The recording was interrupted → always keep the audio and record a
    ///    failed entry, regardless of silence or duration (partial audio
    ///    belongs to the user — see AudioCaptureService, never discarded).
    /// 3. Digital silence → discard.
    /// 4. A finite duration at or above the retryable threshold → keep audio,
    ///    record a failed entry.
    /// 5. Otherwise (no duration, or below threshold, or non-finite) → discard.
    static func decide(
        isDigitalSilence: Bool,
        wasInterrupted: Bool,
        audioPath: String?,
        audioDurationSeconds: Double?
    ) -> Action {
        guard audioPath != nil else { return .nothing }
        if wasInterrupted { return .recordFailedEntry }
        if isDigitalSilence { return .discardAudio }
        if let duration = audioDurationSeconds,
           duration.isFinite,
           duration >= minimumRetryableSeconds {
            return .recordFailedEntry
        }
        return .discardAudio
    }
}

/// Executes the `EmptyResultAudioPolicy` decision against real
/// `HistoryStore`/`HistoryRecorder` collaborators. Both are injected so tests
/// can exercise the digital-silence/interrupted/whisper-empty wiring without
/// AppDelegate or a live NSWindow. docs/plans/empty-result-audio.md §3 C5.
///
/// Invariant: `store` and `recorder` must be backed by the SAME
/// `HistoryStore` instance — `recorder.recordTranscriptionFailure` writes
/// through `HistoryRecorder`'s own (private) store reference, while
/// `discardUnreferencedAudio` is called directly on `store` here; if the two
/// pointed at different stores, a failed-entry write and an audio-discard
/// check could each see a different cache. In production this is
/// `HistoryStore.shared` and `AppDelegate.historyRecorder`
/// (`HistoryRecorder(store: .shared)`, see `AppDelegate.swift`); in tests,
/// both must be built from the same `HistoryStore.test(...)` instance.
@MainActor
struct EmptyResultAudioHandler {
    /// Which empty-result case triggered this call — mirrors
    /// `EmptyResultAudioPolicy.decide`'s `isDigitalSilence` parameter, spelled
    /// out for callers/tests as a named case rather than a bare Bool.
    enum EmptyReason: Equatable {
        case digitalSilence
        case whisperEmpty
    }

    let store: HistoryStore
    let recorder: HistoryRecorder

    /// Decides via `EmptyResultAudioPolicy.decide` and performs the chosen
    /// action. `failure` is only invoked (to build the `FailedTranscription`)
    /// when the decision is `.recordFailedEntry`, so callers with no audio
    /// path never need to construct one.
    @discardableResult
    func handle(
        reason: EmptyReason,
        wasInterrupted: Bool,
        audioPath: String?,
        audioDurationSeconds: Double?,
        failure: (String) -> HistoryRecorder.FailedTranscription
    ) -> EmptyResultAudioPolicy.Action {
        let action = EmptyResultAudioPolicy.decide(
            isDigitalSilence: reason == .digitalSilence,
            wasInterrupted: wasInterrupted,
            audioPath: audioPath,
            audioDurationSeconds: audioDurationSeconds
        )
        switch action {
        case .discardAudio:
            // audioPath != nil is guaranteed by decide()'s own first rule
            // whenever the result isn't .nothing.
            if let audioPath {
                store.discardUnreferencedAudio(named: audioPath)
            }
        case .recordFailedEntry:
            if let audioPath {
                recorder.recordTranscriptionFailure(failure(audioPath))
            }
        case .nothing:
            break
        }
        return action
    }
}
