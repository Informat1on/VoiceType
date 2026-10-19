// EvalEditorWindow.swift — VoiceType Eval Collector
//
// NSWindow wrapper for EvalEditorView.
// Supports two open paths:
//   1. show(entryID:) — opens any history entry by UUID (used by edit button).
//   2. openForLatestEntry() — opens the most recent entry (Cmd+Opt+E hotkey).
// Manages the Save → update HistoryStore → close flow.
//
// 2026-04-27 — Eval Collector (initial implementation)
// 2026-04-27 — entryID-based init added so any history item is editable

import AppKit
import SwiftUI

// MARK: - EvalEditorFocusModel

/// Holds the focus snapshot taken at Cmd+Opt+E. nil → editor was opened without a
/// target (History, or VoiceType frontmost) and "Save & Insert" is absent.
@MainActor
final class EvalEditorFocusModel: ObservableObject {
    @Published private(set) var snapshot: FocusSnapshot?
    var canInsert: Bool { snapshot != nil }

    init(snapshot: FocusSnapshot? = nil) {
        self.snapshot = snapshot
    }

    func update(_ snapshot: FocusSnapshot?) {
        self.snapshot = snapshot
    }
}

// MARK: - EvalEditorWindow

@MainActor
final class EvalEditorWindow: NSWindow {

    // MARK: - Factory

    /// Open an eval editor for the most recent history entry.
    /// Returns nil (caller should show an error toast) if the store is empty.
    @discardableResult
    static func openForLatestEntry() -> EvalEditorWindow? {
        guard let latest = HistoryStore.shared.latestEntry() else {
            return nil
        }
        return open(entryID: latest.id)
    }

    /// Open an eval editor for the given entry ID.
    @discardableResult
    static func open(entryID: UUID, focus: FocusSnapshot? = nil) -> EvalEditorWindow {
        let win = EvalEditorWindow(entryID: entryID, focus: focus)
        win.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        return win
    }

    // MARK: - Properties

    private var entryID: UUID
    private let focusModel: EvalEditorFocusModel
    /// Guards against a second Save & Insert while the first is being processed.
    private var isSubmitting = false

    /// Replace the insertion target — the latest open always wins (nil included).
    func updateFocus(_ snapshot: FocusSnapshot?) {
        focusModel.update(snapshot)
    }

    // MARK: - Init

    private init(entryID: UUID, focus: FocusSnapshot?) {
        self.entryID = entryID
        self.focusModel = EvalEditorFocusModel(snapshot: focus)

        super.init(
            contentRect: NSRect(origin: .zero, size: NSSize(width: 580, height: 520)),
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered,
            defer: false
        )

        title = "Eval Editor"
        isReleasedWhenClosed = false
        center()
        buildContent()
    }

    // MARK: - Content

    private func buildContent() {
        let view = EvalEditorView(
            entryID: entryID,
            onSave: { [weak self] correction, issue in
                self?.handleSave(correction: correction, issue: issue)
            },
            onCancel: { [weak self] in
                self?.close()
            },
            onSaveAndInsert: { [weak self] correction, issue in
                self?.handleSaveAndInsert(correction: correction, issue: issue)
            },
            focusModel: focusModel
        )

        contentView = NSHostingView(rootView: view)
    }

    // MARK: - Save

    private func handleSave(correction: String, issue: String?) {
        guard let entry = HistoryStore.shared.entry(byID: entryID) else {
            // VT-REV-003: entry was evicted by history rotation while the window was
            // open. Do NOT close — the rotation warning banner in EvalEditorView already
            // tells the user to copy their correction. Closing silently here would discard
            // their work. Log the event for diagnostics.
            print("[EvalEditor] Save blocked: entry \(entryID) no longer in history (evicted by rotation). Window stays open so user can copy their correction.")
            return
        }
        let updated = entry.withEvalSaved(correction: correction, issue: issue)
        HistoryStore.shared.update(updated)
        let evalCount = HistoryStore.shared.savedEvalCount()
        print("[EvalEditor] Saved eval pair. Total saved: \(evalCount)")

        // Close immediately — the eval pair is saved in history.jsonl with
        // isSavedEval=true. Users can verify via Settings → Advanced → Open history.
        close()
    }

    // MARK: - Save & Insert

    /// Saves the pair like `handleSave`, closes, then returns focus to the snapshot and
    /// pastes the correction (docs/plans/fix-and-reinsert.md C3/C6).
    private func handleSaveAndInsert(correction: String, issue: String?) {
        guard !isSubmitting else { return }
        isSubmitting = true
        guard let entry = HistoryStore.shared.entry(byID: entryID) else {
            // Evicted by rotation: window stays open (see handleSave), allow retry.
            isSubmitting = false
            return
        }
        guard let snapshot = focusModel.snapshot else {
            isSubmitting = false
            return
        }
        let appName = snapshot.app.localizedName ?? "the app"
        HistoryStore.shared.update(entry.withEvalSaved(correction: correction, issue: issue))
        close()
        Task { @MainActor in
            let outcome = await ReinsertService.shared.reinsert(correction, into: snapshot)
            Self.announce(outcome, appName: appName)
        }
    }

    private static func announce(_ outcome: ReinsertOutcome, appName: String) {
        let delegate = NSApp.delegate as? AppDelegate
        switch outcome {
        case .inserted:
            NSAccessibility.post(
                element: NSApp as AnyObject,
                notification: .announcementRequested,
                userInfo: [
                    .announcement: "Corrected text inserted",
                    .priority: NSAccessibilityPriorityLevel.high.rawValue
                ]
            )
        case .copied:
            delegate?.showErrorToast(title: "Couldn't insert into \(appName)", body: "Copied to clipboard")
        case .failed(let message):
            delegate?.showErrorToast(title: "Couldn't insert", body: message)
        case .busy:
            break
        }
    }
}
