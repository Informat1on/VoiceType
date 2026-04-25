// FocusCaptureService.swift — VoiceType Focus Return (Step 11)
//
// Captures the user's previous app + focused-window screen at hotkey press so:
// 1. The capsule appears on the correct screen (where the user is looking).
// 2. Focus returns to the previous app when the capsule dismisses.
//
// DESIGN.md § Focus Return (mandatory behavior).
// Requires Accessibility permission (already required for keyboard injection).
//
// AX coordinate system note: AXUIElement position values use top-left origin
// in global screen space, with the primary screen's top-left as (0, 0).
// NSScreen.frame uses bottom-left origin. We flip y via the primary screen's
// height to map AX positions into NSScreen coordinate space.
// This mapping is correct for standard single/multi-monitor setups. On unusual
// arrangements (e.g. rotated displays) the fallback to mouse-cursor screen fires
// if the AX window center doesn't land in any screen's frame.

import AppKit
import ApplicationServices

/// Captures the user's previous app + window at hotkey press so we can:
/// 1. Position the capsule on the same screen as the focused window.
/// 2. Restore focus to that app when the capsule dismisses.
///
/// Requires Accessibility permission (already required for typing injection).
/// All AX calls degrade gracefully: if AX is denied or the window query fails,
/// `capturedWindowScreen` falls back to the screen under the mouse cursor,
/// then to `NSScreen.main`.
@MainActor
final class FocusCaptureService {

    // MARK: - Singleton

    static let shared = FocusCaptureService()

    // MARK: - Captured State

    private(set) var capturedApp: NSRunningApplication?
    private(set) var capturedWindowScreen: NSScreen?
    private var capturedWindow: AXUIElement?  // the specific window to raise on restore
    private var capturedAt: Date?
    // internal for tests — allows FocusCaptureServiceTests to assert suppression state directly.
    var isRestoreSuppressed: Bool = false

    // MARK: - Init

    private init() {}

    // MARK: - Public API

    /// Capture frontmost app + focused-window screen. Call at hotkey press,
    /// BEFORE the capsule is shown (so VoiceType is not yet frontmost).
    func capture() {
        // Always reset suppression at the start of every capture attempt — even
        // if the self-capture early-return fires below. The user pressing the
        // hotkey signals "new recording session", which invalidates any prior
        // suppression context (e.g. a mic-denied or accessibility-denied path
        // from a previous session). Without this unconditional reset, a stale
        // isRestoreSuppressed=true from a permission-error path would silently
        // skip focus restore on the next successful recording.
        //
        // Edge case: if the user presses the hotkey AGAIN while an errorInline
        // capsule is still showing (suppression set, auto-dismiss not yet fired),
        // this clears the suppression. The subsequent hide() will then fire
        // restore() — pulling focus from System Settings. This is the correct
        // UX: the user has actively moved on from the permission flow by starting
        // a new recording.
        isRestoreSuppressed = false

        guard let frontmost = NSWorkspace.shared.frontmostApplication,
              !isVoiceTypeApp(frontmost) else {
            // Don't capture ourselves — e.g. user presses hotkey while Settings
            // is frontmost. Preserve the previous good capture instead.
            // Suppression has already been cleared above so the next restore()
            // will proceed normally.
            return
        }
        capturedApp = frontmost
        capturedAt = Date()
        // Try AX first; fall back to mouse-cursor screen if AX fails.
        let (screen, window) = focusedWindowInfo(for: frontmost)
        capturedWindowScreen = screen ?? screenContainingMouse()
        capturedWindow = window
    }

    /// Mark the next `restore()` call as a no-op. Use this when the app has
    /// intentionally directed user focus elsewhere (e.g., System Settings for
    /// permission grant) and pulling focus back to the captured app would
    /// disrupt the user's flow.
    ///
    /// The suppression flag clears after `restore()` is called once, so this is
    /// per-incident, not permanent.
    func suppressNextRestore() {
        isRestoreSuppressed = true
    }

    /// Restore focus to the previously-captured app. Call on capsule final hide.
    /// Best-effort: failures are silently ignored (not user-visible errors per spec).
    func restore() {
        if isRestoreSuppressed {
            isRestoreSuppressed = false
            // Still clear captured state so subsequent natural sessions start fresh.
            clear()
            return
        }
        guard let app = capturedApp,
              !app.isTerminated,
              !isVoiceTypeApp(app) else {
            clear()
            return
        }
        // activate(options:) is the non-deprecated path on macOS 14+.
        // Empty options: bring app to front without hiding other apps.
        app.activate(options: [])
        // If we captured the specific window, raise and focus it via AX.
        // AX calls can fail silently on sandboxed targets — that is acceptable;
        // app activation still works as a fallback.
        if let window = capturedWindow {
            AXUIElementPerformAction(window, kAXRaiseAction as CFString)
            AXUIElementSetAttributeValue(window, kAXMainAttribute as CFString, kCFBooleanTrue)
            AXUIElementSetAttributeValue(window, kAXFocusedAttribute as CFString, kCFBooleanTrue)
        }
        // Don't clear capturedApp/capturedWindowScreen/capturedWindow here — a second
        // restore() call (defensive) should still succeed. capture() on next press will
        // overwrite state.
    }

    /// The captured screen, or NSScreen.main as fallback.
    /// Used by RecordingWindow to position the capsule on the correct display.
    var preferredScreen: NSScreen {
        capturedWindowScreen ?? NSScreen.main ?? NSScreen.screens.first ?? NSScreen()
    }

    /// Reset all captured state. Optional cleanup hook.
    func clear() {
        capturedApp = nil
        capturedWindowScreen = nil
        capturedWindow = nil
        capturedAt = nil
    }

    // MARK: - Private Helpers

    private func isVoiceTypeApp(_ app: NSRunningApplication) -> Bool {
        guard let bundleID = app.bundleIdentifier else { return false }
        return bundleID == Bundle.main.bundleIdentifier
    }

    /// Use the AX API to find the focused window's frame. Returns the screen that
    /// contains its center AND the AXUIElement for the window itself.
    /// Returns (nil, nil) on any AX failure (permission denied, app with no windows,
    /// sandboxed target, etc.).
    private func focusedWindowInfo(for app: NSRunningApplication) -> (NSScreen?, AXUIElement?) {
        let pid = app.processIdentifier
        let appElement = AXUIElementCreateApplication(pid)

        var focusedRef: CFTypeRef?
        let focusResult = AXUIElementCopyAttributeValue(
            appElement,
            kAXFocusedWindowAttribute as CFString,
            &focusedRef
        )
        guard focusResult == .success, let focused = focusedRef else { return (nil, nil) }
        // swiftlint:disable:next force_cast
        let windowElement = focused as! AXUIElement

        var positionRef: CFTypeRef?
        var sizeRef: CFTypeRef?
        let posResult = AXUIElementCopyAttributeValue(
            windowElement,
            kAXPositionAttribute as CFString,
            &positionRef
        )
        let sizeResult = AXUIElementCopyAttributeValue(
            windowElement,
            kAXSizeAttribute as CFString,
            &sizeRef
        )
        guard posResult == .success, sizeResult == .success,
              let posValue = positionRef, let sizeValue = sizeRef else { return (nil, nil) }

        var origin = CGPoint.zero
        var size = CGSize.zero
        // AXValue force-casts are required by Apple's AX API design — the type tag
        // is embedded in the AXValue opaque struct, not the Swift type system.
        // swiftlint:disable:next force_cast
        AXValueGetValue(posValue as! AXValue, .cgPoint, &origin)
        // swiftlint:disable:next force_cast
        AXValueGetValue(sizeValue as! AXValue, .cgSize, &size)

        // AX origin is top-left of the window in global screen space (top-left origin).
        // NSScreen.frame is bottom-left origin with primary screen starting at y=0.
        // Flip: nsY = primaryScreenHeight - axY.
        guard let primaryScreen = NSScreen.screens.first else { return (nil, nil) }
        let primaryHeight = primaryScreen.frame.height
        let windowCenterAX = CGPoint(
            x: origin.x + size.width / 2,
            y: origin.y + size.height / 2
        )
        let windowCenterNS = CGPoint(
            x: windowCenterAX.x,
            y: primaryHeight - windowCenterAX.y
        )

        // Returns nil if the window center is not on any visible screen — caller
        // falls through to screenContainingMouse() then NSScreen.main.
        let screen = NSScreen.screens.first(where: { $0.frame.contains(windowCenterNS) })
        return (screen, windowElement)
    }

    /// Return the screen that contains the current mouse-cursor position.
    private func screenContainingMouse() -> NSScreen? {
        let mouseLocation = NSEvent.mouseLocation
        return NSScreen.screens.first { $0.frame.contains(mouseLocation) }
    }
}
