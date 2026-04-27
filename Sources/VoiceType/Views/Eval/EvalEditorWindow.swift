// EvalEditorWindow.swift — VoiceType Eval Collector
//
// NSWindow wrapper for EvalEditorView. Opens with the latest HistoryStore entry.
// Manages the Save → update HistoryStore → close flow.
//
// 2026-04-27 — Eval Collector (initial implementation)

import AppKit
import SwiftUI

// MARK: - EvalEditorWindow

@MainActor
final class EvalEditorWindow: NSWindow {

    // MARK: - Factory

    /// Open an eval editor for the most recent history entry.
    /// Returns nil and shows a brief notification if the store is empty.
    @discardableResult
    static func openForLatestEntry() -> EvalEditorWindow? {
        guard let entry = HistoryStore.shared.latestEntry() else {
            return nil
        }
        let win = EvalEditorWindow(entry: entry)
        win.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        return win
    }

    // MARK: - Properties

    private var entry: HistoryStore.Entry

    // MARK: - Init

    init(entry: HistoryStore.Entry) {
        self.entry = entry

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
            entry: entry,
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
        let updated = entry.withEvalSaved(correction: correction)
        HistoryStore.shared.update(updated)
        let evalCount = HistoryStore.shared.savedEvalCount()
        print("[EvalEditor] Saved eval pair. Total saved: \(evalCount)")

        // Close immediately — the eval pair is saved in history.jsonl with
        // isSavedEval=true. Users can verify via Settings → Advanced → Open history.
        close()
    }
}
