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
                onDelete: {
                    delete(entry)
                    if selectedID == entry.id { selectedID = nil }
                }
            )
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

        let pb = NSPasteboard.general

        // Snapshot the current clipboard contents before clobbering it.
        let savedItems: [[NSPasteboard.PasteboardType: Data]] = pb.pasteboardItems?.compactMap { item in
            var copy: [NSPasteboard.PasteboardType: Data] = [:]
            for type in item.types {
                if let data = item.data(forType: type) {
                    copy[type] = data
                }
            }
            return copy.isEmpty ? nil : copy
        } ?? []

        // Set history text on the pasteboard.
        pb.clearContents()
        pb.setString(entry.text, forType: .string)

        // Wait for app activation, paste, then restore the original clipboard.
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(150))
            synthesizePaste()
            // Give the paste event time to be consumed before restoring.
            try? await Task.sleep(for: .milliseconds(100))
            pb.clearContents()
            for item in savedItems {
                let pbItem = NSPasteboardItem()
                for (type, data) in item {
                    pbItem.setData(data, forType: type)
                }
                pb.writeObjects([pbItem])
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

    /// Synthesize Cmd+V via CGEvent so re-insert works identically to normal injection.
    private func synthesizePaste() {
        let source = CGEventSource(stateID: .hidSystemState)
        guard
            let cmdDown = CGEvent(keyboardEventSource: source, virtualKey: 0x37, keyDown: true),
            let vDown   = CGEvent(keyboardEventSource: source, virtualKey: 0x09, keyDown: true),
            let vUp     = CGEvent(keyboardEventSource: source, virtualKey: 0x09, keyDown: false),
            let cmdUp   = CGEvent(keyboardEventSource: source, virtualKey: 0x37, keyDown: false)
        else { return }

        vDown.flags = .maskCommand
        vUp.flags   = .maskCommand

        cmdDown.post(tap: .cghidEventTap)
        vDown.post(tap: .cghidEventTap)
        vUp.post(tap: .cghidEventTap)
        cmdUp.post(tap: .cghidEventTap)
    }
}

// MARK: - HistoryListRow

private struct HistoryListRow: View {
    let entry: HistoryStore.Entry
    let isSelected: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(String(entry.text.prefix(80)))
                .font(Typography.body)
                .foregroundStyle(Palette.textPrimary)
                .lineLimit(2)
                .truncationMode(.tail)
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
    let onDelete: () -> Void

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

            // Full transcription text (scrollable)
            ScrollView {
                Text(entry.text)
                    .font(Typography.body)
                    .foregroundStyle(Palette.textPrimary)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(Spacing.lg)
            }

            Divider()

            // Action bar
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

                Spacer()

                Button(role: .destructive, action: onDelete) {
                    Label("Delete", systemImage: "trash")
                }
                .buttonStyle(BorderedButtonStyle())
                .help("Delete this entry")
            }
            .padding(.horizontal, Spacing.lg)
            .padding(.vertical, Spacing.md)
        }
        .background(Palette.bgWindow)
    }
}
