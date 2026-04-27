// ErrorToastWindow.swift — VoiceType
//
// Dedicated NSPanel for unsolvable errors (Step 7).
// Displayed separately from the recording capsule — top-right of screen,
// 20pt from edges. Width 320pt per v4-revisions.html CSS (.toast-error).
// Background #2A1A1A (error surface). 6s auto-dismiss via Task.sleep.
//
// Queuing: every show() call is logged immediately to errors.log via the
// injected logger. If a toast is already visible and has been shown for less
// than minVisibleTime (2.5s), the new toast is queued (FIFO, max 3 entries).
// When the current toast has been visible for at least 2.5s it is dismissed
// and the next queued entry is shown. If the queue is full (3 entries) the
// oldest queued (not currently shown) entry is dropped and a warning is logged.
//
// VoiceOver: callers MUST set CapsuleStateModel.state = .errorToast(title:body:)
// BEFORE or AFTER calling show(title:body:) to fire the announcement.
// AppDelegate wires this via showErrorToast(title:body:).
//
// DESIGN.md § Error Handling & Logging, Step 7.

import AppKit
import SwiftUI

// swiftlint:disable inline_color_hex inline_color_rgb inline_nscolor_rgb

// MARK: - ErrorToastContent (SwiftUI view)

private struct ErrorToastContent: View {
    let title: String
    let message: String
    let onViewLog: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            // Error icon
            Text("!")
                .font(.system(size: 13, weight: .bold))
                .foregroundColor(Color(nsColor: NSColor(hex: "#FF7A6B")))
                .frame(width: 16, height: 16)
                .padding(.top, 1)

            VStack(alignment: .leading, spacing: 2) {
                if !title.isEmpty {
                    Text(title)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundColor(Color(nsColor: NSColor(hex: "#FFDCD5")))
                        .fixedSize(horizontal: false, vertical: true)
                }
                if !message.isEmpty {
                    Text(message)
                        .font(.system(size: 11, weight: .regular))
                        .foregroundColor(Color(nsColor: NSColor(hex: "#FFDCD5")).opacity(0.75))
                        .fixedSize(horizontal: false, vertical: true)
                }
                Button("View log") {
                    onViewLog()
                }
                .buttonStyle(.plain)
                .font(.system(size: 11, weight: .medium))
                .foregroundColor(Color(nsColor: NSColor(hex: "#FF7A6B")))
                .padding(.top, 2)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .frame(width: 320, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color(nsColor: NSColor(hex: "#2A1A1A")))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(
                    Color(nsColor: NSColor(srgbRed: 1.0, green: 0.478431, blue: 0.419608, alpha: 0.35)),
                    lineWidth: 1
                )
        )
    }
}

// MARK: - ErrorToastWindow

/// Floating NSPanel showing unsolvable errors. Created once, reused per show call.
///
/// Every show() call is immediately written to errors.log via `logger`.
/// When a toast is already visible and has been shown for less than
/// `minVisibleTime` (2.5 s), the incoming toast is queued (FIFO, max 3).
/// The fourth enqueue drops the oldest queued entry and logs a warning.
final class ErrorToastWindow: NSPanel {

    // MARK: - Queue entry

    private struct QueueEntry {
        let title: String
        let body: String
    }

    // MARK: - Configuration

    /// Minimum time a toast must stay visible before the next one can replace it.
    /// Exposed as `var` so tests can inject a smaller value for fast execution.
    var minVisibleTime: TimeInterval = 2.5

    /// Maximum number of pending (not-yet-shown) entries in the queue.
    static let maxQueueDepth = 3

    // MARK: - Test seam

    /// Logger closure. Defaults to `ErrorLogger.shared.log(message:category:)`.
    /// Tests inject their own closure to capture log calls without file I/O.
    var logger: (_ message: String, _ category: String) -> Void = { message, category in
        ErrorLogger.shared.log(message: message, category: category)
    }

    // MARK: - Private state

    private var dismissTask: Task<Void, Never>?
    private let hostingView: NSHostingView<ErrorToastContent>
    /// Timestamp when the current toast was first shown (used for min-visible-time).
    private var showStartTime: Date?
    /// Pending toasts not yet displayed.
    private var queue: [QueueEntry] = []

    // MARK: - Init

    init() {
        // Placeholder content — replaced on each show(title:body:) call.
        let placeholder = ErrorToastContent(title: "", message: "", onViewLog: {})
        hostingView = NSHostingView(rootView: placeholder)

        let size = hostingView.fittingSize

        super.init(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: [.borderless, .nonactivatingPanel, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )

        configureWindow()
        contentView = hostingView
    }

    // MARK: - Public API

    /// Show the toast with given content.
    ///
    /// - The toast is logged to errors.log immediately (before any UI change).
    /// - If the window is already visible and has been shown for less than
    ///   `minVisibleTime`, the new entry is queued (FIFO, max 3). If the queue
    ///   is full the oldest queued entry is dropped and a warning is logged.
    /// - If the window is not visible (or min-visible-time has elapsed), the
    ///   toast is shown immediately, replacing any current content.
    /// - Auto-dismisses after 6 seconds unless `persistent` is true.
    /// - Persistent toasts stay visible until `hide()` is called explicitly
    ///   (e.g. by watchForAccessibilityRestart() once permission flips). P2 finding #3.
    func show(title: String, body: String, persistent: Bool = false) {
        // Log immediately — before any UI mutation — per DESIGN.md §Error Handling & Logging:
        // "Every error logged before UI surface appears."
        logger("\(title): \(body)", "toast")

        // If currently visible and within the min-visible window, queue the entry.
        if isVisible, let start = showStartTime, Date().timeIntervalSince(start) < minVisibleTime {
            enqueue(QueueEntry(title: title, body: body))
            return
        }

        displayImmediately(title: title, body: body, persistent: persistent)
    }

    func hide() {
        dismissTask?.cancel()
        dismissTask = nil
        showStartTime = nil
        orderOut(nil)
        showNextQueued()
    }

    // MARK: - Private — display

    private func displayImmediately(title: String, body: String, persistent: Bool = false) {
        dismissTask?.cancel()
        dismissTask = nil

        // Rebuild content view with new strings.
        hostingView.rootView = ErrorToastContent(
            title: title,
            message: body,
            onViewLog: { [weak self] in self?.openLogFile() }
        )

        // Size to fit content, then position.
        let fitting = hostingView.fittingSize
        setContentSize(fitting)
        positionTopRight()

        showStartTime = Date()
        orderFrontRegardless()

        if !persistent {
            dismissTask = Task { @MainActor [weak self] in
                guard let self else { return }
                // Wait until at least minVisibleTime has elapsed since show.
                let elapsed = Date().timeIntervalSince(self.showStartTime ?? Date())
                let remaining = max(self.minVisibleTime, 6.0) - elapsed
                try? await Task.sleep(for: .seconds(remaining))
                guard !Task.isCancelled else { return }
                self.hide()
            }
        }
    }

    // MARK: - Private — queue management

    private func enqueue(_ entry: QueueEntry) {
        if queue.count >= ErrorToastWindow.maxQueueDepth {
            let dropped = queue.removeFirst()
            logger("Toast queue full — dropped: \(dropped.title): \(dropped.body)", "toast-warning")
        }
        queue.append(entry)
    }

    private func showNextQueued() {
        guard !queue.isEmpty else { return }
        let next = queue.removeFirst()
        displayImmediately(title: next.title, body: next.body)
    }

    // MARK: - Private — window

    private func configureWindow() {
        backgroundColor = .clear
        isOpaque = false
        hasShadow = true
        level = .floating
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        ignoresMouseEvents = false // toast has a "View log" button
        animationBehavior = .none
        isReleasedWhenClosed = false
    }

    private func positionTopRight() {
        // Use the menu-bar screen (first in `screens`), not `NSScreen.main` which
        // follows the key window. The toast is a system-level notification and
        // should consistently appear on the primary display regardless of where
        // the user is focused. P2 finding #4.
        guard let screen = NSScreen.screens.first else { return }
        let screenFrame = screen.visibleFrame
        let margin: CGFloat = 20

        let x = screenFrame.maxX - frame.width - margin
        let y = screenFrame.maxY - frame.height - margin

        setFrameOrigin(NSPoint(x: x, y: y))
    }

    private func openLogFile() {
        let logURL = ErrorLogger.shared.currentLogFileURL
        let fileManager = FileManager.default

        if fileManager.fileExists(atPath: logURL.path) {
            NSWorkspace.shared.open(logURL)
        } else {
            // Fall back to directory if today's log doesn't exist yet.
            NSWorkspace.shared.open(ErrorLogger.shared.logDirectoryURL)
        }
    }
}

// swiftlint:enable inline_color_hex inline_color_rgb inline_nscolor_rgb
