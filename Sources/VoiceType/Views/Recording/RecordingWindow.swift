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
    /// Initial value MUST NOT be `.recording` — otherwise `CapsuleIndicatorView.onAppear`
    /// starts the timer anchor at app launch, and the first user recording shows
    /// stale elapsed time (e.g. "0:14"). `.transcribing` is a safe transient:
    /// `onChange` fires when AppDelegate calls `show(.recording)`, resetting the anchor.
    @Published var state: CapsuleState = .transcribing

    // MARK: - A7: errorInline auto-dismiss

    /// Called when state transitions to .errorInline. After `seconds` the model
    /// posts .capsuleErrorInlineExpired so AppDelegate can hide the window.
    /// AppDelegate wiring (voiceTypeWindow?.hide()) is Phase 2 work.
    /// The callback is decoupled via NotificationCenter to avoid a direct
    /// AppDelegate import in this file.
    func scheduleErrorInlineDismiss(after seconds: TimeInterval = 4) {
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(seconds))
            if case .errorInline = state {
                NotificationCenter.default.post(name: .capsuleErrorInlineExpired, object: nil)
            }
        }
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
