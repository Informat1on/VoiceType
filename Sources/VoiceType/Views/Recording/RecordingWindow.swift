// RecordingWindow.swift — VoiceType Tier A Step 6
//
// CapsuleState: 6-case enum replaces VoiceTypeState (recording/processing).
// VoiceTypeWindow: single NSHostingView + @Published CapsuleStateModel for
// zero-teardown state transitions and smooth animations.
//
// DESIGN.md § Recording capsule — three zones.
// DESIGN.md § Interaction States — Capsule.
// DESIGN.md § Implementation Plan Step 6.

import AppKit
import SwiftUI

// MARK: - CapsuleState

/// Six-case display state for the recording capsule.
/// Replaces the old VoiceTypeState (recording/processing only).
/// DESIGN.md § Interaction States — Capsule.
enum CapsuleState: Equatable {
    case recording
    case transcribing
    case inserted(charCount: Int, targetAppName: String)
    case errorInline(message: String)
    /// errorToast requires a separate NSWindow (Step 7 territory).
    /// For now, render like errorInline. TODO: Step 7 — dedicated toast window.
    case errorToast(title: String, body: String)
    case emptyResult
}

// MARK: - CapsuleStateModel

/// Observable model owned by VoiceTypeWindow. A single instance persists
/// for the lifetime of the window — state changes via @Published, not
/// NSHostingView replacement. Enables smooth SwiftUI transitions across all
/// 6 capsule states without window teardown overhead.
/// DESIGN.md Decisions Log D2: single NSHostingView + @Published CapsuleState.
final class CapsuleStateModel: ObservableObject {

    // MARK: - VoiceOver announcer seam

    /// Injectable announcer for testability. Default calls NSAccessibility.post on NSApp
    /// (system-wide target — VoiceOver speaks the announcement regardless of keyboard focus,
    /// which is correct for a floating capsule that intentionally ignores mouse/keyboard events).
    /// Copy taken verbatim from v6-a11y.html § 6.3, lines 271–276.
    typealias Announcer = (String) -> Void

    static let defaultAnnouncer: Announcer = { message in
        NSAccessibility.post(
            element: NSApp as AnyObject,
            notification: .announcementRequested,
            userInfo: [
                .announcement: message,
                .priority: NSAccessibilityPriorityLevel.high.rawValue
            ]
        )
    }

    var announcer: Announcer = CapsuleStateModel.defaultAnnouncer

    // MARK: - State

    /// Initial value MUST NOT be `.recording` — otherwise `CapsuleIndicatorView.onAppear`
    /// starts the timer anchor at app launch, and the first user recording shows
    /// stale elapsed time (e.g. "0:14"). `.transcribing` is a safe transient:
    /// `onChange` fires when AppDelegate calls `show(.recording)`, resetting the anchor.
    @Published var state: CapsuleState = .transcribing {
        didSet { announceStateChange(state) }
    }

    // MARK: - A7: errorInline auto-dismiss

    /// Tracks the most-recent pending dismiss task so rapid errorInline transitions
    /// can cancel the stale timer before scheduling a new one (P3 codex fix).
    private var pendingDismissTask: Task<Void, Never>?

    /// Called when state transitions to .errorInline. After `seconds` the model
    /// posts .capsuleErrorInlineExpired so AppDelegate can hide the window.
    /// AppDelegate wiring (voiceTypeWindow?.hide()) is Phase 2 work.
    /// The callback is decoupled via NotificationCenter to avoid a direct
    /// AppDelegate import in this file.
    ///
    /// P3: cancels the previous pending task before scheduling a new one.
    /// This ensures each errorInline message receives its own full display window:
    /// without cancellation, a stale task can fire and hide a newer message early.
    func scheduleErrorInlineDismiss(after seconds: TimeInterval = 4) {
        pendingDismissTask?.cancel()
        pendingDismissTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(seconds))
            guard !Task.isCancelled, let self else { return }
            if case .errorInline = self.state {
                NotificationCenter.default.post(name: .capsuleErrorInlineExpired, object: nil)
            }
        }
    }

    // MARK: - VoiceOver announcement

    private func announceStateChange(_ newState: CapsuleState) {
        let message = announcementCopy(for: newState)
        guard !message.isEmpty else { return }
        announcer(message)
    }

    /// Returns verbatim announcement copy per v6-a11y.html § 6.3, lines 271–276.
    /// Internal (not private) so unit tests can verify copy without OS involvement.
    func announcementCopy(for capsuleState: CapsuleState) -> String {
        switch capsuleState {
        case .recording:
            // v6-a11y.html line 271: appear → "VoiceType recording. Speak now."
            return "VoiceType recording. Speak now."
        case .transcribing:
            // v6-a11y.html line 272: transcribing → "Transcribing."
            return "Transcribing."
        case let .inserted(charCount, appName):
            // v6-a11y.html line 273: inserted → "Inserted {N} characters into {appName}."
            return "Inserted \(charCount) characters into \(appName)."
        case .emptyResult:
            // v6-a11y.html line 274: empty-result → "Nothing heard."
            return "Nothing heard."
        case let .errorInline(message):
            // v6-a11y.html line 275: error (inline) → "{error text}. {action hint}."
            // Normalize punctuation (same helper as toast) and guarantee a single
            // trailing period for VoiceOver pacing. Empty input → empty output so the
            // guard in announceStateChange skips the announcement.
            let normalized = Self.normalizePunctuation(message)
            return normalized.isEmpty ? "" : "\(normalized)."
        case let .errorToast(title, body):
            // v6-a11y.html line 276: error (toast) → {toast title} + {toast body}
            // Normalize: strip trailing terminal punctuation from each part before
            // joining so body strings like "Reload the model." don't produce
            // doubled periods ("Reload the model..") in the VoiceOver output.
            let parts = [
                Self.normalizePunctuation(title),
                Self.normalizePunctuation(body)
            ].filter { !$0.isEmpty }
            guard !parts.isEmpty else { return "" }
            return parts.joined(separator: ". ") + "."
        }
    }

    /// Strips trailing whitespace and terminal punctuation (`.`, `!`, `?`) from `s`.
    private static func normalizePunctuation(_ s: String) -> String {
        s.trimmingCharacters(in: .whitespacesAndNewlines)
         .trimmingCharacters(in: CharacterSet(charactersIn: ".!?"))
    }
}

// MARK: - VoiceTypeWindow

final class VoiceTypeWindow: NSWindow {

    /// Exposed for AppDelegate to mutate state directly.
    let stateModel = CapsuleStateModel()
    private let audioService: AudioCaptureService

    init(audioService: AudioCaptureService) {
        self.audioService = audioService

        let rect = NSRect(
            x: 0,
            y: 0,
            width: VoiceTypeCapsuleMetrics.totalWidth,
            height: VoiceTypeCapsuleMetrics.totalHeight
        )

        super.init(
            contentRect: rect,
            styleMask: [.borderless, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )

        configureWindow()

        // Single NSHostingView created once in init — never replaced.
        // State flows via stateModel.state (@Published ObservableObject).
        let rootView = CapsuleRootView(stateModel: stateModel, audioService: audioService)
        contentView = NSHostingView(rootView: rootView)
    }

    // MARK: - Public API

    /// Update the capsule state, position at top-center, and bring to front.
    func show(state: CapsuleState) {
        stateModel.state = state
        positionAtTopCenter()
        orderFrontRegardless()
    }

    func hide() {
        orderOut(nil)
    }

    // MARK: - Private

    private func configureWindow() {
        backgroundColor = .clear
        isOpaque = false
        hasShadow = false
        level = .floating
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        ignoresMouseEvents = true
        animationBehavior = .none
    }

    private func positionAtTopCenter() {
        guard let screen = NSScreen.main else { return }
        let screenFrame = screen.frame
        let topOffset: CGFloat = 80

        let x = screenFrame.midX - frame.width / 2
        let y = screenFrame.maxY - frame.height - topOffset

        setFrameOrigin(NSPoint(x: x, y: y))
    }
}

// MARK: - VoiceTypeCapsuleMetrics

/// Capsule geometry constants. CapsuleSize (width/height) lives in Tokens.swift.
/// Shadow padding gives room for the drop shadow without clipping.
enum VoiceTypeCapsuleMetrics {
    static let shadowPadding: CGFloat = 16
    static let totalWidth: CGFloat = CapsuleSize.width + shadowPadding * 2
    static let totalHeight: CGFloat = CapsuleSize.height + shadowPadding * 2
}
