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
    static func open(entryID: UUID) -> EvalEditorWindow {
        let win = EvalEditorWindow(entryID: entryID)
        win.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        return win
    }

    // MARK: - Properties

    private var entryID: UUID

    // MARK: - Init

    private init(entryID: UUID) {
        self.entryID = entryID

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
            onSave: { [weak self] correction in
                self?.handleSave(correction: correction)
            },
            onCancel: { [weak self] in
                self?.close()
            }
        )

        contentView = NSHostingView(rootView: view)
    }

    // MARK: - Save

    private func handleSave(correction: String) {
        guard let entry = HistoryStore.shared.entry(byID: entryID) else {
            // Entry was deleted while the window was open — just close.
            print("[EvalEditor] Entry \(entryID) not found during save — closing.")
            close()
            return
        }
        let updated = entry.withEvalSaved(correction: correction)
        HistoryStore.shared.update(updated)
        let evalCount = HistoryStore.shared.savedEvalCount()
        print("[EvalEditor] Saved eval pair. Total saved: \(evalCount)")

        // Close immediately — the eval pair is saved in history.jsonl with
        // isSavedEval=true. Users can verify via Settings → Advanced → Open history.
        close()
    }
}
