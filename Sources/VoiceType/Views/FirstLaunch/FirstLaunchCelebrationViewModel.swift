// FirstLaunchCelebrationViewModel.swift — VoiceType Phase 2.5 Chunk X
//
// Extracted state machine for the first-launch celebration arc.
// Keeping this separate from the View enables unit testing without AppKit.
//
// Celebration arc (normal motion):
//   200ms — tick bounce on the just-flipped badge  (hasCelebrated gate)
//   200ms — "All set" text fades + slides in       (showCelebration gate)
//   400ms — hold, user reads the line
//   300ms — window dismisses (scale + opacity)
//   Total: 1100ms
//
// Reduced motion (accessibilityReduceMotion = true):
//   skip tick bounce, pure opacity fade for "All set", hold 200ms,
//   dismiss instant opacity-only over 100ms (Motion.micro).
//   Total: ~300ms
//
// Edge cases gated by this view model:
//   • `hasCelebrated` — fires exactly once per window session.
//   • `hadUnsatisfiedBlockerAtOpen` — only celebrate if at least one
//     step was unsatisfied when the window first opened (prevents
//     immediate-celebrate on re-open when already complete).

import Combine
import Foundation

// MARK: - FirstLaunchCelebrationViewModel

/// Pure state machine — no AppKit/SwiftUI imports, fully testable.
final class FirstLaunchCelebrationViewModel: ObservableObject {

    // MARK: Published state

    /// Set to true when "All set" text should appear.
    @Published private(set) var showCelebration: Bool = false

    /// Set to true while the just-completed badge should bounce.
    @Published private(set) var bounceBadge: Bool = false

    // MARK: Internal flags

    /// Prevents the celebration from firing more than once per window session.
    private(set) var hasCelebrated: Bool = false

    /// Set to true if at least one blocker was unsatisfied at window-open time.
    /// Prevents the "re-open when all green" path from celebrating.
    private(set) var hadUnsatisfiedBlockerAtOpen: Bool = false

    // MARK: Dependencies (injectable for tests)

    /// True when the system reduce-motion preference is active.
    /// Injected so tests can exercise both branches without AppKit.
    var reduceMotion: Bool = false

    /// Closure that triggers the window dismiss sequence after the hold.
    /// Injected so tests can capture the call without a real NSWindow.
    var onDismiss: (() -> Void)?

    /// Scheduling back-end. Defaults to DispatchQueue.main; tests may substitute.
    var schedule: (_ delay: Double, _ block: @escaping () -> Void) -> Void = { delay, block in
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: block)
    }

    // MARK: - API

    /// Called once at window-open time to record whether any blockers were unmet.
    /// Must be called before `handleBlockersSatisfied()` can trigger a celebration.
    func recordOpenState(allBlockersSatisfiedAtOpen: Bool) {
        hadUnsatisfiedBlockerAtOpen = !allBlockersSatisfiedAtOpen
    }

    /// Call whenever the set of satisfied blockers changes.
    /// Triggers the celebration arc if conditions are met.
    func handleBlockersSatisfied() {
        guard !hasCelebrated, hadUnsatisfiedBlockerAtOpen else { return }
        hasCelebrated = true

        // Phase 1: badge bounce (starts immediately, Motion.short = 200ms).
        // The View applies `.scaleEffect` driven by `bounceBadge`.
        if !reduceMotion {
            bounceBadge = true
            schedule(Motion.short) { [weak self] in
                self?.bounceBadge = false
            }
        }

        // Phase 2: "All set" reveal starts at +200ms (after badge bounce or immediately).
        let allSetDelay = reduceMotion ? 0.0 : Motion.short
        schedule(allSetDelay) { [weak self] in
            self?.showCelebration = true
        }

        // Phase 3: Hold + Phase 4: Dismiss.
        // hold = 400ms normal / 200ms reduced. Dismiss signal at end of hold.
        let holdDuration: Double = reduceMotion ? 0.2 : 0.4
        let dismissDelay = allSetDelay + holdDuration
        schedule(dismissDelay) { [weak self] in
            self?.onDismiss?()
        }
    }

    // MARK: - Just-flipped step targeting

    /// Returns the step number that should bounce when blockers transition.
    /// Prefers a step in `current \ previous` (the step the user JUST satisfied).
    /// Falls back to the highest currently-satisfied step when there's no diff
    /// (e.g., the very first call when previous == current).
    /// Pure function — testable without AppKit/SwiftUI.
    static func justFlippedHighest(previous: Set<Int>, current: Set<Int>) -> Int? {
        current.subtracting(previous).max() ?? current.max()
    }

    // MARK: - Timing query (used by tests)

    /// Returns the total delay from handleBlockersSatisfied() to onDismiss() call.
    /// Normal: 200ms (badge) + 0ms (concurrent all-set) + 400ms hold = 600ms.
    /// Wait — see spec: badge 200ms + all-set starts at +200ms + hold 400ms = 600ms to dismiss signal.
    /// But dismiss animation itself is 300ms after that, so window closes at 900ms.
    /// This property returns the delay to the onDismiss() *call* (not window.close()).
    var dismissDelay: Double {
        let allSetDelay = reduceMotion ? 0.0 : Motion.short
        let holdDuration: Double = reduceMotion ? 0.2 : 0.4
        return allSetDelay + holdDuration
    }
}
