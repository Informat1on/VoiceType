// HistorySection.swift — VoiceType
//
// Self-contained Settings UI for Transcription History.
// Kept in its own file so the call-site in SettingsView.swift (and Chunk H's
// forthcoming rewrite of that file) only needs a single line: `HistorySection()`.
//
// DESIGN.md § Transcription History. Step 9.

import SwiftUI
import AppKit

// MARK: - HistorySection

/// Plug-in view for the Transcription History group inside Settings → Advanced.
/// Loads entries from HistoryStore on appear and reflects mutations immediately.
struct HistorySection: View {

    @State private var entries: [HistoryStore.Entry] = []
    @State private var isSheetPresented: Bool = false

    var body: some View {
        // Two rows separated by a RowDivider.
        // The surrounding call-site (SettingsView) handles the outer RowDividers
        // and the GroupHeader — HistorySection emits only its row content.
        PrefsRow("Transcription history",
                 subtitle: summarySubtitle) {
            Button("Open history") {
                isSheetPresented = true
            }
            .buttonStyle(BorderedButtonStyle())
            .disabled(entries.isEmpty)
        }
        RowDivider()
        PrefsRow("Entries") {
            Text("\(entries.count)")
                .font(Typography.mono)
                .foregroundStyle(Palette.textSecondary)
        }
        .onAppear { reloadEntries() }
        .sheet(isPresented: $isSheetPresented, onDismiss: reloadEntries) {
            HistorySheetView(entries: $entries, onReloadEntries: reloadEntries)
        }
    }

    // MARK: - Helpers

    private var summarySubtitle: String {
        guard !entries.isEmpty else {
            return "No transcriptions recorded yet."
        }
        let count = entries.count
        // entries is newest-first; last element is oldest.
        if let oldest = entries.last {
            let formatted = oldest.timestamp.formatted(
                .dateTime.month(.abbreviated).day().year()
            )
            return "\(count) \(count == 1 ? "entry" : "entries") saved · oldest from \(formatted)"
        }
        return "\(count) \(count == 1 ? "entry" : "entries") saved"
    }

    private func reloadEntries() {
        entries = HistoryStore.shared.entries()
    }
}

// MARK: - HistorySheetView

/// 800 × 560 master–detail sheet: list on the left, detail on the right.
private struct HistorySheetView: View {

    @Binding var entries: [HistoryStore.Entry]
    let onReloadEntries: () -> Void

    @State private var selectedID: UUID?
    @Environment(\.dismiss) private var dismiss

    private var selectedEntry: HistoryStore.Entry? {
        guard let id = selectedID else { return nil }
        return entries.first { $0.id == id }
    }

    var body: some View {
        VStack(spacing: 0) {
            // Title bar
            HStack {
                Text("Transcription History")
                    .font(Typography.sectionTitle)
                    .foregroundStyle(Palette.textPrimary)
                Spacer()
                Button("Done") { dismiss() }
                    .buttonStyle(BorderedButtonStyle())
            }
            .padding(.horizontal, Spacing.lg)
            .padding(.vertical, Spacing.md)

            Divider()

            if entries.isEmpty {
                emptyState
            } else {
                HSplitView {
                    historyList
                        .frame(minWidth: 260, idealWidth: 280, maxWidth: 320)
                    detailPanel
                        .frame(maxWidth: .infinity)
                }
            }
        }
        .frame(width: 800, height: 560)
        .background(Palette.bgWindow)
    }

    // MARK: - Empty state

    private var emptyState: some View {
        VStack(spacing: Spacing.sm) {
            Text("No transcription history yet.")
                .font(Typography.body)
                .foregroundStyle(Palette.textSecondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - List panel

    private var historyList: some View {
        ScrollView {
            LazyVStack(spacing: 0) {
                ForEach(entries) { entry in
                    HistoryListRow(
                        entry: entry,
                        isSelected: entry.id == selectedID
                    )
                    .contentShape(Rectangle())
                    .onTapGesture { selectedID = entry.id }
                    Divider().opacity(0.5)
                }
            }
        }
        .background(Palette.surfaceInset)
    }

    // MARK: - Detail panel

    @ViewBuilder
    private var detailPanel: some View {
        if let entry = selectedEntry {
            HistoryDetailView(
                entry: entry,
                onReinsert: { reinsert(entry) },
                onCopy: { copy(entry) },
                onEdit: { openEvalEditor(for: entry) },
                onDelete: {
                    delete(entry)
                    if selectedID == entry.id { selectedID = nil }
                },
                onRetry: { await retryTranscription(entry) }
            )
            // Ties HistoryDetailView's identity to the selected entry, so its
            // @State (retry-in-flight flag, last retry outcome) resets whenever
            // the user picks a different row. A successful retry keeps the same
            // id (the entry stops being failed but isn't reselected), so the
            // in-flight state intentionally survives that transition.
            .id(entry.id)
        } else {
            VStack {
                Text("Select an entry to view details.")
                    .font(Typography.body)
                    .foregroundStyle(Palette.textMuted)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    // MARK: - Actions

    private func reinsert(_ entry: HistoryStore.Entry) {
        // Activate target app first (DESIGN.md mandate).
        if let bundleID = entry.targetAppBundleID,
           let app = NSRunningApplication.runningApplications(
               withBundleIdentifier: bundleID
           ).first {
            app.activate(options: [])
        }

        // Wait for app activation, then paste through the same full-clipboard
        // preserving path as live dictation (docs/plans/reliable-dictation.md § D1).
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(150))
            do {
                _ = try await TextInjectionService().insertText(entry.text, mode: .paste, pressEnterAfter: false)
            } catch {
                ErrorLogger.shared.log(error, category: "insertion")
            }
        }

        dismiss()
    }

    private func copy(_ entry: HistoryStore.Entry) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(entry.text, forType: .string)
    }

    private func delete(_ entry: HistoryStore.Entry) {
        HistoryStore.shared.delete(entry.id)
        entries = HistoryStore.shared.entries()
        onReloadEntries()
    }

    /// D4/E: reruns ASR on a failed entry's saved audio via AppDelegate, then
    /// reloads entries the same way `delete(_:)` does. `selectedID` is left
    /// untouched — since it's the entry's `id` (unchanged by a retry), the
    /// detail panel keeps showing the same entry, now updated.
    private func retryTranscription(_ entry: HistoryStore.Entry) async -> RetryTranscriptionOutcome {
        let outcome = await (NSApp.delegate as? AppDelegate)?.retryTranscription(for: entry.id) ?? .failed
        entries = HistoryStore.shared.entries()
        onReloadEntries()
        return outcome
    }

    private func openEvalEditor(for entry: HistoryStore.Entry) {
        // VT-REV-001: route through AppDelegate so the window gets strong ownership
        // and duplicate windows are prevented. AppDelegate tracks all open editors
        // in evalEditorWindows[UUID] and cleans up on NSWindow.willCloseNotification.
        if let delegate = NSApp.delegate as? AppDelegate {
            delegate.openEvalEditorForEntry(entry.id)
        } else {
            // Fallback: direct open (window ownership not tracked — acceptable for
            // edge cases where AppDelegate is unavailable, e.g. previews/tests).
            EvalEditorWindow.open(entryID: entry.id)
        }
    }
}

// MARK: - HistoryListRow

private struct HistoryListRow: View {
    let entry: HistoryStore.Entry
    let isSelected: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            if entry.isFailed {
                Text("Transcription failed")
                    .font(Typography.body)
                    .foregroundStyle(Palette.error)
                    .lineLimit(2)
            } else {
                Text(String(entry.text.prefix(80)))
                    .font(Typography.body)
                    .foregroundStyle(Palette.textPrimary)
                    .lineLimit(2)
                    .truncationMode(.tail)
            }
            HStack(spacing: Spacing.xs) {
                Text(entry.timestamp.formatted(.relative(presentation: .named)))
                    .font(Typography.caption)
                    .foregroundStyle(Palette.textMuted)
                Text("·")
                    .font(Typography.caption)
                    .foregroundStyle(Palette.textMuted)
                Text(entry.targetAppName)
                    .font(Typography.caption)
                    .foregroundStyle(Palette.textMuted)
                Text("·")
                    .font(Typography.caption)
                    .foregroundStyle(Palette.textMuted)
                Text(entry.language)
                    .font(Typography.caption)
                    .foregroundStyle(Palette.textMuted)
            }
        }
        .padding(.horizontal, Spacing.md)
        .padding(.vertical, Spacing.sm)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(isSelected ? Palette.sidebarActive : Color.clear)
    }
}

// MARK: - HistoryDetailView

private struct HistoryDetailView: View {
    let entry: HistoryStore.Entry
    let onReinsert: () -> Void
    let onCopy: () -> Void
    let onEdit: () -> Void
    let onDelete: () -> Void
    /// D4/E: reruns ASR on this (failed) entry's saved audio. Never inserts
    /// text — only fills in the entry, which the caller reloads.
    let onRetry: () async -> RetryTranscriptionOutcome

    @State private var isRetrying = false
    @State private var retryOutcome: RetryTranscriptionOutcome?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Header metadata
            VStack(alignment: .leading, spacing: Spacing.xs) {
                Text(entry.timestamp.formatted(
                    .dateTime.weekday(.wide).month(.wide).day().year()
                    .hour().minute().second()
                ))
                .font(Typography.mono)
                .foregroundStyle(Palette.textMuted)

                HStack(spacing: Spacing.sm) {
                    Label(entry.targetAppName, systemImage: "app.badge")
                        .font(Typography.caption)
                        .foregroundStyle(Palette.textSecondary)
                    Text("·")
                        .font(Typography.caption)
                        .foregroundStyle(Palette.textMuted)
                    Text(entry.language)
                        .font(Typography.caption)
                        .foregroundStyle(Palette.textSecondary)
                    Text("·")
                        .font(Typography.caption)
                        .foregroundStyle(Palette.textMuted)
                    Text("\(entry.charCount) chars")
                        .font(Typography.caption)
                        .foregroundStyle(Palette.textMuted)
                }
            }
            .padding(.horizontal, Spacing.lg)
            .padding(.top, Spacing.lg)
            .padding(.bottom, Spacing.md)

            Divider()

            // Full transcription text (scrollable), or the failure explanation.
            ScrollView {
                if entry.isFailed {
                    Text("Transcription failed (\(failureReasonText)). "
                        + "The audio is saved — you can run recognition again.")
                        .font(Typography.body)
                        .foregroundStyle(Palette.textPrimary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(Spacing.lg)
                } else {
                    Text(entry.text)
                        .font(Typography.body)
                        .foregroundStyle(Palette.textPrimary)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(Spacing.lg)
                }
            }

            Divider()

            // Action bar
            VStack(alignment: .leading, spacing: Spacing.xs) {
                if entry.isFailed {
                    HStack(spacing: Spacing.sm) {
                        Button(action: retry) {
                            HStack(spacing: Spacing.xs) {
                                Label("Retry transcription", systemImage: "arrow.clockwise")
                                if isRetrying {
                                    ProgressView()
                                        .controlSize(.small)
                                }
                            }
                        }
                        .buttonStyle(BorderedButtonStyle())
                        .disabled(entry.audioPath == nil || isRetrying)
                        .help("Run recognition again on the saved audio")

                        Spacer()

                        Button(role: .destructive, action: onDelete) {
                            Label("Delete", systemImage: "trash")
                        }
                        .buttonStyle(BorderedButtonStyle())
                        .help("Delete this entry")
                    }

                    if let retryStatusText {
                        Text(retryStatusText)
                            .font(Typography.caption)
                            .foregroundStyle(Palette.error)
                    }
                } else {
                    HStack(spacing: Spacing.sm) {
                        Button(action: onReinsert) {
                            Label("Re-insert", systemImage: "arrow.uturn.left")
                        }
                        .buttonStyle(BorderedButtonStyle())
                        .help("Re-insert into \(entry.targetAppName)")

                        Button(action: onCopy) {
                            Label("Copy", systemImage: "doc.on.doc")
                        }
                        .buttonStyle(BorderedButtonStyle())
                        .help("Copy text to clipboard")

                        Button(action: onEdit) {
                            Label("Edit", systemImage: "square.and.pencil")
                        }
                        .buttonStyle(BorderedButtonStyle())
                        .help("Open in Eval Editor to review and correct")

                        Spacer()

                        Button(role: .destructive, action: onDelete) {
                            Label("Delete", systemImage: "trash")
                        }
                        .buttonStyle(BorderedButtonStyle())
                        .help("Delete this entry")
                    }
                }
            }
            .padding(.horizontal, Spacing.lg)
            .padding(.vertical, Spacing.md)
        }
        .background(Palette.bgWindow)
    }

    // MARK: - Failed-entry helpers

    private var failureReasonText: String {
        switch entry.failureReason {
        case "timeout": return "timed out"
        case "empty": return "no speech recognized"
        default: return "error"
        }
    }

    private func retry() {
        guard !isRetrying else { return }
        isRetrying = true
        retryOutcome = nil
        Task {
            let outcome = await onRetry()
            isRetrying = false
            retryOutcome = outcome
        }
    }

    private var retryStatusText: String? {
        guard let retryOutcome else { return nil }
        switch retryOutcome {
        case .transcribed, .notFailed:
            return nil
        case .busy:
            return "VoiceType is busy — try again in a moment."
        case .entryMissing:
            return "This entry no longer exists."
        case .audioMissing:
            return "The audio file is missing."
        case .emptyResult:
            return "No speech recognized."
        case .failed:
            return "Recognition failed again — see Diagnostics → errors.log."
        }
    }
}
