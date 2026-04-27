// EvalEditorView.swift — VoiceType Eval Collector
//
// Modal editor for reviewing and correcting the last whisper transcription.
// Opens via Cmd+Opt+E hotkey or the "Edit last transcription" menu item.
//
// Design: DESIGN.md aesthetic — Cool Ink-Steel palette, Geist/Geist Mono,
// native rows + dividers, no glassmorphism.
//
// Flow:
//   1. Show whisper output read-only.
//   2. Pre-fill editable correction field with whisper output.
//   3. Save button enabled only when correction differs from whisper output.
//   4. On Save: update HistoryStore entry with userCorrection + isSavedEval=true.
//   5. Show brief "Saved eval pair #N" notification, then close.
//
// 2026-04-27 — Eval Collector (initial implementation)

import SwiftUI
import AVFoundation

// MARK: - EvalEditorView

struct EvalEditorView: View {

    // MARK: - Initialisation

    /// Designated initialiser. Window manages the entry lifecycle.
    let entryID: UUID
    let onSave: (_ correction: String) -> Void
    let onCancel: () -> Void

    /// Resolved entry — loaded from HistoryStore on appear.
    /// Nil means the entry was deleted from history while the window was open.
    @State private var entry: HistoryStore.Entry?

    @State private var correctionText: String = ""
    @State private var isPlayingAudio = false
    @State private var audioPlayer: AVAudioPlayer?
    @State private var playbackProgress: Double = 0
    @State private var playbackTimer: Timer?
    /// VT-REV-003: tracks whether the entry still exists in HistoryStore.
    /// Polled every 2 s so the user sees a warning if history rotation evicts the entry.
    @State private var stillExists: Bool = true
    @State private var rotationPollTimer: Timer?

    /// Primary init: takes an explicit entry ID — works for any history entry.
    init(entryID: UUID, onSave: @escaping (_ correction: String) -> Void, onCancel: @escaping () -> Void) {
        self.entryID = entryID
        self.onSave = onSave
        self.onCancel = onCancel
    }

    // MARK: - Factory

    /// Convenience factory for the Cmd+Opt+E hotkey path — opens the most recent entry.
    /// Returns nil when the history store is empty (caller should show a toast instead).
    @MainActor
    static func lastEntry(
        onSave: @escaping (_ correction: String) -> Void,
        onCancel: @escaping () -> Void
    ) -> EvalEditorView? {
        guard let latest = HistoryStore.shared.latestEntry() else { return nil }
        return EvalEditorView(entryID: latest.id, onSave: onSave, onCancel: onCancel)
    }

    // MARK: - Computed

    private var isCorrectionChanged: Bool {
        guard let entry else { return false }
        return correctionText != entry.text
    }

    private var audioFileURL: URL? {
        guard let path = entry?.audioPath else { return nil }
        return HistoryStore.shared.audioDirectory.appendingPathComponent(path)
    }

    private var hasAudio: Bool {
        guard let url = audioFileURL else { return false }
        return FileManager.default.fileExists(atPath: url.path)
    }

    private var formattedDuration: String {
        guard let dur = entry?.audioDurationSeconds else { return "" }
        let secs = Int(dur)
        return String(format: "%d:%02d", secs / 60, secs % 60)
    }

    // MARK: - Body

    var body: some View {
        Group {
            if entry != nil {
                loadedBody
            } else {
                notFoundBody
            }
        }
        .frame(width: 580)
        .onAppear {
            let resolved = HistoryStore.shared.entry(byID: entryID)
            entry = resolved
            correctionText = resolved?.text ?? ""
            // VT-REV-003: poll every 2 s to detect entry rotation while the editor is open.
            rotationPollTimer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { _ in
                Task { @MainActor in
                    let exists = HistoryStore.shared.entry(byID: entryID) != nil
                    if !exists && stillExists {
                        stillExists = false
                    }
                }
            }
        }
        .onDisappear {
            stopPlayback()
            rotationPollTimer?.invalidate()
            rotationPollTimer = nil
        }
    }

    /// Shown while the entry is still in the history store.
    private var loadedBody: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Palette.divider.frame(height: 1)
            metaRow
            Palette.divider.frame(height: 1)
            if hasAudio {
                audioRow
                Palette.divider.frame(height: 1)
            }
            contentArea
            // VT-REV-003: rotation warning — shown when entry was evicted from history
            // while the editor was open. Saving will fail; user must copy corrections first.
            if !stillExists {
                rotationWarningBanner
                Palette.divider.frame(height: 1)
            }
            Palette.divider.frame(height: 1)
            footer
        }
        .background(Palette.bgWindow)
    }

    /// Banner displayed when the entry has been evicted from history rotation.
    private var rotationWarningBanner: some View {
        HStack(spacing: Spacing.sm) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(Palette.warning)
            Text("This transcription was removed from history. Copy your correction before closing — saving will fail.")
                .font(Typography.caption)
                .foregroundStyle(Palette.warning)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, Spacing.xl)
        .padding(.vertical, Spacing.md)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Palette.warning.opacity(0.08))
        .accessibilityLabel("Warning: this transcription was removed from history. Saving will fail.")
    }

    /// Fallback shown when the entry was deleted while the window was open.
    private var notFoundBody: some View {
        VStack(spacing: Spacing.lg) {
            Image(systemName: "exclamationmark.triangle")
                .font(.system(size: 32))
                .foregroundStyle(Palette.textMuted)
            Text("Entry not found")
                .font(Typography.sectionTitle)
                .foregroundStyle(Palette.textPrimary)
            Text("This transcription was removed from history.")
                .font(Typography.body)
                .foregroundStyle(Palette.textSecondary)
            Button("Close", action: onCancel)
                .buttonStyle(VoiceTypeSecondaryButtonStyle())
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(Spacing.xl)
        .background(Palette.bgWindow)
    }

    // MARK: - Header

    private var header: some View {
        HStack {
            Text("Eval — Transcription")
                .font(Typography.sectionTitle)
                .foregroundStyle(Palette.textPrimary)
            Spacer()
            Button(action: onCancel) {
                Image(systemName: "xmark.circle.fill")
                    .foregroundStyle(Palette.textMuted)
                    .font(.system(size: 16))
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Close")
        }
        .padding(.horizontal, Spacing.xl)
        .padding(.vertical, Spacing.md)
    }

    // MARK: - Meta row

    private var metaRow: some View {
        HStack(spacing: Spacing.lg) {
            if let modelName = entry?.model {
                metaChip(label: "MODEL", value: modelName)
            }
            if let lang = entry?.language {
                metaChip(label: "LANG", value: lang.uppercased())
            }
            if let dur = entry?.audioDurationSeconds {
                metaChip(label: "DUR", value: String(format: "%.1fs", dur))
            }
            Spacer()
            // Show eval status badge if already saved
            if entry?.isSavedEval == true {
                Text("SAVED")
                    .font(Typography.metaLabel)
                    .tracking(Typography.metaLabelTracking)
                    .textCase(.uppercase)
                    .foregroundStyle(Palette.success)
                    .padding(.horizontal, Spacing.sm)
                    .padding(.vertical, Spacing.xs)
                    .background(Palette.success.opacity(0.12))
                    .clipShape(Capsule())
            }
        }
        .padding(.horizontal, Spacing.xl)
        .padding(.vertical, Spacing.md)
    }

    private func metaChip(label: String, value: String) -> some View {
        HStack(spacing: 4) {
            Text(label)
                .font(Typography.metaLabel)
                .tracking(Typography.metaLabelTracking)
                .textCase(.uppercase)
                .foregroundStyle(Palette.textMuted)
            Text(value)
                .font(Typography.mono)
                .foregroundStyle(Palette.textSecondary)
                .monospacedDigit()
        }
    }

    // MARK: - Audio row

    private var audioRow: some View {
        HStack(spacing: Spacing.md) {
            Button(action: togglePlayback) {
                Image(systemName: isPlayingAudio ? "pause.fill" : "play.fill")
                    .font(.system(size: 14))
                    .foregroundStyle(Palette.accent)
                    .frame(width: 28, height: 28)
                    .background(Palette.accentSoft)
                    .clipShape(Circle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(isPlayingAudio ? "Pause" : "Play audio")

            // Progress bar
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 2)
                        .fill(Palette.strokeSubtle)
                        .frame(height: 4)
                    RoundedRectangle(cornerRadius: 2)
                        .fill(Palette.accent)
                        .frame(width: geo.size.width * playbackProgress, height: 4)
                }
                .frame(maxHeight: .infinity)
                .contentShape(Rectangle())
                .onTapGesture { location in
                    seekAudio(to: location.x / geo.size.width)
                }
            }
            .frame(height: 20)

            if !formattedDuration.isEmpty {
                Text(formattedDuration)
                    .font(Typography.mono)
                    .foregroundStyle(Palette.textMuted)
                    .monospacedDigit()
                    .frame(width: 40, alignment: .trailing)
            }
        }
        .padding(.horizontal, Spacing.xl)
        .padding(.vertical, Spacing.md)
    }

    // MARK: - Content area (whisper output + correction)

    private var contentArea: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Whisper output (read-only)
            VStack(alignment: .leading, spacing: Spacing.xs) {
                Text("WHISPER OUTPUT")
                    .font(Typography.metaLabel)
                    .tracking(Typography.metaLabelTracking)
                    .textCase(.uppercase)
                    .foregroundStyle(Palette.textMuted)

                ScrollView {
                    Text(entry?.text ?? "")
                        .font(Typography.body)
                        .foregroundStyle(Palette.textSecondary)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(minHeight: 60, maxHeight: 100)
                .padding(Spacing.sm)
                .background(Palette.surfaceInset)
                .clipShape(RoundedRectangle(cornerRadius: Radius.control))
                .overlay(
                    RoundedRectangle(cornerRadius: Radius.control)
                        .stroke(Palette.strokeSubtle, lineWidth: 1)
                )
            }
            .padding(.horizontal, Spacing.xl)
            .padding(.top, Spacing.lg)
            .padding(.bottom, Spacing.md)

            Palette.divider.frame(height: 1)

            // Correction field (editable, pre-filled)
            VStack(alignment: .leading, spacing: Spacing.xs) {
                HStack {
                    Text("YOUR CORRECTION")
                        .font(Typography.metaLabel)
                        .tracking(Typography.metaLabelTracking)
                        .textCase(.uppercase)
                        .foregroundStyle(Palette.textMuted)
                    Spacer()
                    if isCorrectionChanged {
                        Text("edited")
                            .font(Typography.caption)
                            .foregroundStyle(Palette.accent)
                    }
                }

                TextEditor(text: $correctionText)
                    .font(Typography.body)
                    .foregroundStyle(Palette.textPrimary)
                    .frame(minHeight: 80, maxHeight: 140)
                    .padding(Spacing.sm)
                    .background(Palette.bgWindow)
                    .clipShape(RoundedRectangle(cornerRadius: Radius.control))
                    .overlay(
                        RoundedRectangle(cornerRadius: Radius.control)
                            .stroke(
                                isCorrectionChanged ? Palette.accentStrong : Palette.strokeSubtle,
                                lineWidth: isCorrectionChanged ? 1.5 : 1
                            )
                    )
            }
            .padding(.horizontal, Spacing.xl)
            .padding(.top, Spacing.md)
            .padding(.bottom, Spacing.lg)
        }
    }

    // MARK: - Footer

    private var footer: some View {
        HStack(spacing: Spacing.sm) {
            Button("Cancel", action: onCancel)
                .buttonStyle(VoiceTypeSecondaryButtonStyle())
                .keyboardShortcut(.escape, modifiers: [])

            Spacer()

            Button("Save eval pair") {
                onSave(correctionText)
            }
            .buttonStyle(VoiceTypePrimaryButtonStyle())
            .disabled(!isCorrectionChanged)
            .keyboardShortcut(.return, modifiers: .command)
            .accessibilityLabel(
                isCorrectionChanged
                    ? "Save correction as eval pair"
                    : "No changes to save"
            )
        }
        .padding(.horizontal, Spacing.xl)
        .padding(.vertical, Spacing.md)
    }

    // MARK: - Audio playback

    private func togglePlayback() {
        if isPlayingAudio {
            stopPlayback()
        } else {
            startPlayback()
        }
    }

    private func startPlayback() {
        guard let url = audioFileURL else { return }
        do {
            let player = try AVAudioPlayer(contentsOf: url)
            player.prepareToPlay()
            player.play()
            audioPlayer = player
            isPlayingAudio = true

            // Update progress every 50ms.
            playbackTimer = Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { [self] _ in
                guard let player = audioPlayer else { return }
                if player.isPlaying {
                    playbackProgress = player.duration > 0
                        ? player.currentTime / player.duration : 0
                } else {
                    // Finished naturally.
                    playbackProgress = 0
                    isPlayingAudio = false
                    playbackTimer?.invalidate()
                    playbackTimer = nil
                }
            }
        } catch {
            print("[EvalEditor] Audio playback failed: \(error)")
        }
    }

    private func stopPlayback() {
        playbackTimer?.invalidate()
        playbackTimer = nil
        audioPlayer?.stop()
        audioPlayer = nil
        isPlayingAudio = false
    }

    private func seekAudio(to fraction: Double) {
        guard let player = audioPlayer else { return }
        player.currentTime = player.duration * max(0, min(1, fraction))
        playbackProgress = fraction
    }
}

// MARK: - Button Styles
// swiftlint:disable no_grouping_extension

private struct VoiceTypePrimaryButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(Typography.buttonLabel)
            .foregroundStyle(isEnabled ? Color.white : Palette.textMuted)
            .padding(.horizontal, ButtonPadding.horizontal)
            .padding(.vertical, ButtonPadding.vertical)
            .background(
                RoundedRectangle(cornerRadius: Radius.control)
                    .fill(isEnabled ? Palette.accent : Palette.strokeSubtle)
            )
            .opacity(configuration.isPressed ? 0.8 : 1)
            .animation(.easeInOut(duration: Motion.micro), value: configuration.isPressed)
    }
}

private struct VoiceTypeSecondaryButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(Typography.buttonLabel)
            .foregroundStyle(Palette.textSecondary)
            .padding(.horizontal, ButtonPadding.horizontal)
            .padding(.vertical, ButtonPadding.vertical)
            .background(
                RoundedRectangle(cornerRadius: Radius.control)
                    .stroke(Palette.strokeSubtle, lineWidth: 1)
            )
            .opacity(configuration.isPressed ? 0.7 : 1)
            .animation(.easeInOut(duration: Motion.micro), value: configuration.isPressed)
    }
}

// swiftlint:enable no_grouping_extension
