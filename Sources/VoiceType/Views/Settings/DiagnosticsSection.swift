// DiagnosticsSection.swift — VoiceType
//
// Settings → Advanced → Diagnostics row. Wires up the previously dead
// "Open Log" button (task 3, architectural audit finding): ErrorLogger has
// been fully implemented since 2026-04-27 (daily rotation + 7-day retention,
// already used by ErrorToastWindow's "View log" link) — see TODOS.md T5 —
// but the Settings row still had `Button("Open Log") {}.disabled(true)`.
//
// DESIGN.md § Error Handling & Logging § Settings access specifies TWO
// actions, not one: "Reveal in Finder" and "Clear" — not a single "Open Log".
//
// Extracted to its own file (same pattern as HistorySection.swift) so
// SettingsView.swift doesn't grow further and the entry-count state is
// self-contained.

import SwiftUI
import AppKit

struct DiagnosticsSection: View {

    @State private var entryCount: Int = 0

    var body: some View {
        PrefsRow("Error log", subtitle: summarySubtitle) {
            HStack(spacing: Spacing.sm) {
                // Never disabled: the log directory is worth opening even when
                // today's file is empty, because rotated archives from the last
                // 7 days can still be there — and after Clear that is exactly
                // the state the user is left in. Review finding, wave A.
                Button("Reveal in Finder") {
                    revealInFinder()
                }
                .buttonStyle(BorderedButtonStyle())

                Button("Clear") {
                    ErrorLogger.shared.clear()
                    reloadEntryCount()
                }
                .buttonStyle(BorderedButtonStyle())
                .disabled(entryCount == 0)
            }
        }
        .onAppear { reloadEntryCount() }
    }

    // MARK: - Helpers

    /// DESIGN.md line 451: "~/Library/Logs/VoiceType/errors.log · N entries".
    /// The path is the tilde-shorthand from DESIGN.md, not the resolved
    /// absolute path — the row is a location hint, not a literal file browser.
    private var summarySubtitle: String {
        "~/Library/Logs/VoiceType/errors.log · \(entryCount) \(entryCount == 1 ? "entry" : "entries")"
    }

    private func reloadEntryCount() {
        entryCount = ErrorLogger.shared.entryCount()
    }

    private func revealInFinder() {
        let logURL = ErrorLogger.shared.currentLogFileURL
        if FileManager.default.fileExists(atPath: logURL.path) {
            NSWorkspace.shared.activateFileViewerSelecting([logURL])
        } else {
            // Fall back to the directory if today's log doesn't exist yet —
            // mirrors ErrorToastWindow.openLogFile()'s fallback (P2 review finding).
            NSWorkspace.shared.activateFileViewerSelecting([ErrorLogger.shared.logDirectoryURL])
        }
    }
}
