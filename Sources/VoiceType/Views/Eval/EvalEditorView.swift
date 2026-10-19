// EvalEditorView.swift — VoiceType Eval Collector
//
// Modal editor for reviewing and correcting the last whisper transcription.
// Opens via Cmd+Opt+E hotkey or the "Edit last transcription" menu item.
//
// Design: DESIGN.md aesthetic — Cool Ink-Steel palette, Geist/Geist Mono,
// native rows + dividers, no glassmorphism.
//
// Flow:
//   1. Show whisper output read-only (raw + final, side by side, when the
//      pipeline changed the text — see rawText).
//   2. Pre-fill editable correction field with whisper output.
//   3. Save button: unedited correction saves a control ("correct") example;
//      an edited correction saves an eval pair with an optional issue class.
//   4. On Save: update HistoryStore entry with userCorrection + isSavedEval=true
//      (+ evalIssue when an eval pair, nil for a control example).
//   5. Show brief "Saved eval pair #N" notification, then close.
//
// 2026-04-27 — Eval Collector (initial implementation)
// 2026-09-24 — "Save as correct" control examples, issue class, raw/final split.
// Errors were the only thing accumulating in history — no control examples to
// compare against in the replay-based quality harness. See DESIGN.md Decisions Log.

import SwiftUI
import AVFoundation

// EvalIssueOption / EvalSaveButtonState / EvalEditorView.saveButtonState(entry:correction:)
// live in EvalEditorView+SaveState.swift (kept out of this file to stay under
// its file_length lint budget).

// MARK: - EvalEditorView

struct EvalEditorView: View {

    // MARK: - Initialisation

    /// Designated initialiser. Window manages the entry lifecycle.
    let entryID: UUID
    let onSave: (_ correction: String, _ issue: String?) -> Void
    let onCancel: () -> Void
    /// Save & Insert: nil closure or empty model → no button (docs/plans/fix-and-reinsert.md C5).
    var onSaveAndInsert: ((_ correction: String, _ issue: String?) -> Void)?
    @ObservedObject var focusModel: EvalEditorFocusModel

    /// Resolved entry — loaded from HistoryStore on appear.
    /// Nil means the entry was deleted from history while the window was open.
    @State private var entry: HistoryStore.Entry?

    @State private var correctionText: String = ""
    /// Eval issue class picker selection (R3/K2). Only surfaced — and only
    /// consulted on Save — when `saveState == .saveEvalPair`.
    @State private var selectedIssue: EvalIssueOption = .notSet
    @State private var isPlayingAudio = false
    @State private var audioPlayer: AVAudioPlayer?
    @State private var playbackProgress: Double = 0
    @State private var playbackTimer: Timer?
    /// Поколение текущей попытки воспроизведения. Код-ревью 2026-09-18: без
    /// него Stop (или закрытие экрана) до прихода `perform`-completion не
    /// защищал от гонки — поздний `.success` сохранял бы плеер, который уже
    /// никто не остановит, а быстрый повторный старт мог перетереть плеер
    /// новой попытки плеером старой. Инкрементируется в `startPlayback()` и
    /// `stopPlayback()`; completion применяет результат только если
    /// захваченное значение совпадает с текущим.
    @State private var playbackGeneration = 0
    /// VT-REV-003: tracks whether the entry still exists in HistoryStore.
    /// Polled every 2 s so the user sees a warning if history rotation evicts the entry.
    @State private var stillExists: Bool = true
    @State private var rotationPollTimer: Timer?

    /// Primary init: takes an explicit entry ID — works for any history entry.
    @MainActor
    init(
        entryID: UUID,
        onSave: @escaping (_ correction: String, _ issue: String?) -> Void,
        onCancel: @escaping () -> Void,
        onSaveAndInsert: ((_ correction: String, _ issue: String?) -> Void)? = nil,
        focusModel: EvalEditorFocusModel? = nil
    ) {
        self.entryID = entryID
        self.onSave = onSave
        self.onCancel = onCancel
        self.onSaveAndInsert = onSaveAndInsert
        self.focusModel = focusModel ?? EvalEditorFocusModel()
    }

    // MARK: - Factory

    /// Convenience factory for the Cmd+Opt+E hotkey path — opens the most recent entry.
    /// Returns nil when the history store is empty (caller should show a toast instead).
    @MainActor
    static func lastEntry(
        onSave: @escaping (_ correction: String, _ issue: String?) -> Void,
        onCancel: @escaping () -> Void
    ) -> EvalEditorView? {
        guard let latest = HistoryStore.shared.latestEntry() else { return nil }
        return EvalEditorView(entryID: latest.id, onSave: onSave, onCancel: onCancel)
    }

    // MARK: - Computed

    private var saveState: EvalSaveButtonState {
        Self.saveButtonState(entry: entry, correction: correctionText)
    }

    private var isCorrectionChanged: Bool {
        guard let entry else { return false }
        return correctionText != entry.text
    }

    /// Footer button label (R3): "Save as correct" for an unedited control
    /// example, "Save eval pair" otherwise — including while disabled, so the
    /// label doesn't flicker as the user types.
    private var saveButtonTitle: String {
        saveState == .saveAsCorrect ? "Save as correct" : "Save eval pair"
    }

    private var saveButtonAccessibilityLabel: String {
        switch saveState {
        case .saveAsCorrect: return "Save transcription as a correct control example"
        case .saveEvalPair: return "Save correction as eval pair"
        case .disabled: return "Nothing to save"
        }
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
            selectedIssue = .notSet
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
            // Whisper output (read-only). Raw + final as two blocks when the
            // pipeline changed the text — no diff highlighting (deliberate,
            // see DESIGN.md Decisions Log).
            if let raw = entry?.rawText {
                readOnlyTextBlock(label: "RAW (BEFORE POST-PROCESSING)", text: raw, minHeight: 40, maxHeight: 80)
                Palette.divider.frame(height: 1)
                readOnlyTextBlock(label: "FINAL TEXT", text: entry?.text ?? "")
            } else {
                readOnlyTextBlock(label: "WHISPER OUTPUT", text: entry?.text ?? "")
            }

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

                if saveState == .saveEvalPair {
                    issuePicker
                }
            }
            .padding(.horizontal, Spacing.xl)
            .padding(.top, Spacing.md)
            .padding(.bottom, Spacing.lg)
        }
    }

    /// Read-only text block shared by WHISPER OUTPUT / RAW / FINAL TEXT (R3).
    private func readOnlyTextBlock(label: String, text: String, minHeight: CGFloat = 60, maxHeight: CGFloat = 100) -> some View {
        VStack(alignment: .leading, spacing: Spacing.xs) {
            Text(label)
                .font(Typography.metaLabel)
                .tracking(Typography.metaLabelTracking)
                .textCase(.uppercase)
                .foregroundStyle(Palette.textMuted)

            ScrollView {
                Text(text)
                    .font(Typography.body)
                    .foregroundStyle(Palette.textSecondary)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(minHeight: minHeight, maxHeight: maxHeight)
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
    }

    /// Issue-class segmented picker (R3/K2), shown only when `saveState ==
    /// .saveEvalPair`. Uses the shared `SegmentedControl`, not a native
    /// `Picker(.segmented)` — see DESIGN.md Decisions Log 2026-09-24.
    private var issuePicker: some View {
        VStack(alignment: .leading, spacing: Spacing.xs) {
            Text("ISSUE")
                .font(Typography.metaLabel)
                .tracking(Typography.metaLabelTracking)
                .textCase(.uppercase)
                .foregroundStyle(Palette.textMuted)

            SegmentedControl(
                options: EvalIssueOption.allCases.map { (label: $0.label, value: $0) },
                selection: $selectedIssue
            )
            .accessibilityLabel("Eval issue class")
        }
        .padding(.top, Spacing.sm)
    }

    // MARK: - Footer

    private var footer: some View {
        HStack(spacing: Spacing.sm) {
            Button("Cancel", action: onCancel)
                .buttonStyle(VoiceTypeSecondaryButtonStyle())
                .keyboardShortcut(.escape, modifiers: [])

            Spacer()

            if focusModel.canInsert, let onSaveAndInsert {
                SaveAndInsertButton(
                    appName: focusModel.snapshot?.app.localizedName ?? "the app",
                    isEnabled: saveState == .saveEvalPair
                ) { onSaveAndInsert(correctionText, selectedIssue.rawIssue) }
            }

            Button(saveButtonTitle) {
                // Saving without edits is a control example — evalIssue is
                // forced to nil regardless of any stale picker selection
                // (the picker is hidden in this state, but the state can't
                // leak into the saved record either way).
                let issue = saveState == .saveAsCorrect ? nil : selectedIssue.rawIssue
                onSave(correctionText, issue)
            }
            .buttonStyle(ChecklistPrimaryButtonStyle())
            .disabled(saveState == .disabled)
            .keyboardShortcut(.return, modifiers: .command)
            .accessibilityLabel(saveButtonAccessibilityLabel)
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
        // Новая попытка обесценивает любую предыдущую в полёте — см. doc
        // `playbackGeneration` выше (код-ревью 2026-09-18, гонка Stop/повторный
        // Play против ещё не пришедшего completion).
        playbackGeneration += 1
        let generation = playbackGeneration
        // Создание плеера, prepareToPlay() и play() — внутри
        // AudioHALGateway.perform (docs/plans/coreaudiod-hang-resilience.md,
        // задача 3): оба вызова висят навсегда, если coreaudiod мёртв (план,
        // «Контекст»). Плеер и isPlayingAudio/таймер выставляются только в
        // completion на main, и только при .success — при .unresponsive
        // кнопка просто остаётся в исходном состоянии, без toast (это экран
        // разработчика — eval-плеер, а не пользовательский путь записи).
        AudioHALGateway.shared.perform("evalPlayback") {
            // Вызов внутри AudioHALGateway.perform — main HAL не трогает.
            // swiftlint:disable:next hal_outside_gateway
            let player = try AVAudioPlayer(contentsOf: url)
            player.prepareToPlay()
            player.play()
            return player
        } completion: { result in
            // Поколение устарело: Stop или новый Play уже сбросили UI, пока
            // этот вызов летел (код-ревью 2026-09-18, P1). Успевший
            // проиграться плеер никому не принадлежит — останавливаем его
            // через шлюз и не сохраняем; устаревший .failure не требует
            // никакого действия, UI уже в исходном состоянии.
            guard generation == playbackGeneration else {
                if case .success(let player) = result {
                    AudioHALGateway.shared.enqueueCleanup("evalPlaybackStale") {
                        player.stop()
                    }
                }
                return
            }
            switch result {
            case .success(let player):
                audioPlayer = player
                isPlayingAudio = true

                // Update progress every 50ms. Геттеры player.isPlaying/
                // currentTime/duration оставлены как есть (не через шлюз) —
                // осознанный остаточный риск на экране разработчика (план,
                // задача 3, п.3).
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
            case .failure(let error):
                print("[EvalEditor] Audio playback failed: \(error)")
                isPlayingAudio = false
            }
        }
    }

    private func stopPlayback() {
        // Инкремент ДО остального: если ещё летит completion от
        // AudioHALGateway.perform (запущенного в startPlayback), он увидит
        // устаревшее поколение и остановит свой плеер сам, а не перезапишет
        // им audioPlayer/isPlayingAudio уже после Stop (код-ревью 2026-09-18,
        // P1). Так же страхует onDisappear, который зовёт stopPlayback().
        playbackGeneration += 1
        playbackTimer?.invalidate()
        playbackTimer = nil
        isPlayingAudio = false
        // stop() — через enqueueCleanup: main не должен трогать HAL напрямую,
        // даже на выходе (план, задача 3, п.3). UI-состояние сбрасывается
        // сразу, сам player.stop() выполнится на очереди шлюза.
        let player = audioPlayer
        audioPlayer = nil
        AudioHALGateway.shared.enqueueCleanup("evalPlaybackStop") {
            player?.stop()
        }
    }

    private func seekAudio(to fraction: Double) {
        guard let player = audioPlayer else { return }
        player.currentTime = player.duration * max(0, min(1, fraction))
        playbackProgress = fraction
    }
}
