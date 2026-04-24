// WaveformView.swift — VoiceType Tier A Step 6
//
// Three-zone capsule rewrite per DESIGN.md § Recording capsule — three zones.
// All colors from Palette.Capsule.* — no inline RGB literals.
//
//  ┌──────────────────────────────────────────┐
//  │  ● REC  RU/EN   ▮▮▮▮▮▮▮▮    0:14       │
//  └──────────────────────────────────────────┘
//    Zone 1 (leading)  Zone 2 (center)  Zone 3 (trailing)
//
// DESIGN.md § Interaction States — Capsule (6 states).
// DESIGN.md § Departure 1: honest waveform (silent during silence).

// swiftlint:disable inline_color_rgb inline_color_hex inline_nscolor_rgb

import SwiftUI

// MARK: - CapsuleRootView

/// Root view for the VoiceTypeWindow hosting view. Observes CapsuleStateModel
/// and delegates rendering to CapsuleIndicatorView.
struct CapsuleRootView: View {
    @ObservedObject var stateModel: CapsuleStateModel
    @ObservedObject var audioService: AudioCaptureService

    var body: some View {
        CapsuleIndicatorView(state: stateModel.state, audioService: audioService)
    }
}

// MARK: - CapsuleIndicatorView

struct CapsuleIndicatorView: View {

    let state: CapsuleState
    @ObservedObject var audioService: AudioCaptureService
    @ObservedObject private var settings = AppSettings.shared

    // Timer state
    @State private var recordingDuration: TimeInterval = 0
    private let durationTimer = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    // Waveform state (audio-driven, silent at rest per Departure 1)
    @State private var waveHistory: [Float] = Array(repeating: 0, count: 16)
    private let levelTimer = Timer.publish(every: 0.05, on: .main, in: .common).autoconnect()

    // Transcribing dot-breathing state
    @State private var dotScale: CGFloat = 0.7
    @State private var dotOffset: CGFloat = 0

    // Tally dot pulse (audio-threshold-gated, NOT continuous)
    @State private var tallyScale: CGFloat = 1.0

    var body: some View {
        ZStack {
            capsuleBody
        }
        .frame(width: VoiceTypeCapsuleMetrics.totalWidth, height: VoiceTypeCapsuleMetrics.totalHeight)
        .onReceive(levelTimer) { _ in
            guard state == .recording else { return }
            waveHistory.append(audioService.audioLevel)
            if waveHistory.count > 16 { waveHistory.removeFirst() }
        }
        .onReceive(durationTimer) { _ in
            guard state == .recording else { return }
            recordingDuration += 1
        }
        // NOTE: single-parameter onChange is the macOS 13 API.
        .onChange(of: state) { newState in
            handleStateChange(newState)
        }
        .onAppear {
            handleStateChange(state)
        }
    }

    // MARK: - Capsule body

    private var capsuleBody: some View {
        ZStack {
            // Background — opaque dark per DESIGN.md (no .ultraThinMaterial)
            Capsule()
                .fill(Palette.Capsule.bg)

            // Border — state-specific
            Capsule()
                .strokeBorder(borderColor, lineWidth: 1)

            // Content
            capsuleContent
                .padding(.horizontal, Spacing.capsuleHorizontal)
        }
        .frame(width: CapsuleSize.width, height: CapsuleSize.height)
        // Shadow per DESIGN.md: 0 2px 8px rgba(0,0,0,0.5), 0 0 16px recording-glow
        .shadow(color: Color.black.opacity(0.50), radius: 4, x: 0, y: 2)
        .shadow(color: Palette.Capsule.recordingGlow, radius: 8, x: 0, y: 0)
        .animation(.easeInOut(duration: Motion.short), value: state)
    }

    // MARK: - Border color per state

    private var borderColor: Color {
        switch state {
        case .recording:              return Palette.Capsule.borderRec
        case .errorInline, .errorToast: return Palette.Capsule.borderErr
        default:                      return Palette.Capsule.borderIdle
        }
    }

    // MARK: - Content per state

    @ViewBuilder
    private var capsuleContent: some View {
        switch state {
        case .recording:
            recordingZones
                .transition(.opacity.combined(with: .scale(scale: 0.97)))
        case .transcribing:
            transcribingContent
                .transition(.opacity.combined(with: .scale(scale: 0.97)))
        case let .inserted(charCount, appName):
            centeredLabel("Inserted \u{00B7} \(charCount) chars \u{2192} \(appName)")
                .foregroundStyle(Palette.success)
                .transition(.opacity.combined(with: .scale(scale: 0.97)))
        case let .errorInline(message):
            centeredLabel(message)
                .foregroundStyle(Palette.Capsule.borderErr)
                .transition(.opacity.combined(with: .scale(scale: 0.97)))
        case let .errorToast(title, _):
            // TODO: Step 7 — render as separate toast NSWindow.
            // For now: inline error treatment.
            centeredLabel(title)
                .foregroundStyle(Palette.Capsule.borderErr)
                .transition(.opacity.combined(with: .scale(scale: 0.97)))
        case .emptyResult:
            centeredLabel("Nothing heard")
                .foregroundStyle(Palette.Capsule.timer)
                .transition(.opacity.combined(with: .scale(scale: 0.97)))
        }
    }

    // MARK: - Recording: three zones

    private var recordingZones: some View {
        HStack(spacing: 0) {
            // Zone 1 — leading: tally + REC label + RU/EN chip
            leadingZone

            // Zone 2 — center: audio waveform (silent at rest)
            Spacer(minLength: 8)
            waveformZone
            Spacer(minLength: 8)

            // Zone 3 — trailing: MM:SS timer
            timerZone
        }
    }

    // MARK: Zone 1: leading

    private var leadingZone: some View {
        HStack(spacing: 5) {
            // Tally dot — 8pt, recording red, audio-threshold pulse
            Circle()
                .fill(Palette.Capsule.recording)
                .frame(width: MenuBar.tallyDotSize, height: MenuBar.tallyDotSize)
                .scaleEffect(tallyScale)

            // REC label — Geist Mono 10/14 Semibold uppercase tracked
            // Colorblind secondary signal. DESIGN.md § Colorblind.
            Text("REC")
                .font(Typography.badge)
                .foregroundStyle(Palette.Capsule.recording)
                .textCase(.uppercase)
                .tracking(0.88)  // 0.08em × 10pt = 0.8 ≈ 0.88 visual match

            // RU/EN chip — display only in v1.1 (not clickable)
            ruEnChip
        }
    }

    private var ruEnChip: some View {
        let chipText = chipLabel

        return Text(chipText)
            .font(Typography.badge)
            .foregroundStyle(Palette.Capsule.timer)
            .tracking(0.6)   // 0.06em × 10pt = 0.6
            .padding(.horizontal, 4)
            .padding(.vertical, 1)
            .overlay(
                Capsule()
                    .strokeBorder(Palette.Capsule.borderIdle, lineWidth: 1)
            )
    }

    private var chipLabel: String {
        switch settings.language {
        case .ru:           return "RU"
        case .en:           return "EN"
        case .bilingualRuEn: return "RU/EN"
        case .auto:         return "AUTO"
        }
    }

    // MARK: Zone 2: waveform

    private var waveformZone: some View {
        CapsuleWaveformView(history: waveHistory, level: audioService.audioLevel)
            .frame(width: 60, height: 20)
    }

    // MARK: Zone 3: timer

    private var timerZone: some View {
        Text(formattedDuration)
            .font(Typography.mono)
            .foregroundStyle(Palette.Capsule.timer)
            .monospacedDigit()
            .frame(minWidth: 30, alignment: .trailing)
    }

    private var formattedDuration: String {
        let total = max(0, Int(recordingDuration))
        let minutes = total / 60
        let seconds = total % 60
        return String(format: "%d:%02d", minutes, seconds)
    }

    // MARK: - Transcribing: 3-dot breathing

    private var transcribingContent: some View {
        HStack(spacing: 4) {
            // Muted tally (gray)
            Circle()
                .fill(Palette.Capsule.timer)
                .frame(width: MenuBar.tallyDotSize, height: MenuBar.tallyDotSize)

            Text("TRANSCRIBING")
                .font(Typography.badge)
                .foregroundStyle(Palette.Capsule.timer)
                .textCase(.uppercase)
                .tracking(0.44)

            Spacer(minLength: 8)

            // 3-dot breathing indicator (Motion.long = 500ms cycle)
            HStack(spacing: 4) {
                ForEach(0..<3, id: \.self) { idx in
                    Circle()
                        .fill(Palette.Capsule.timer)
                        .frame(width: 5, height: 5)
                        .scaleEffect(dotScale)
                        .animation(
                            .easeInOut(duration: Motion.long)
                                .repeatForever(autoreverses: true)
                                .delay(Double(idx) * Motion.long / 3.0),
                            value: dotScale
                        )
                }
            }
        }
    }

    // MARK: - Centered single-line label (inserted / error / emptyResult)

    private func centeredLabel(_ text: String) -> some View {
        HStack {
            Spacer()
            Text(text)
                .font(Typography.metaLabel)
                .foregroundStyle(Palette.Capsule.text)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
            Spacer()
        }
    }

    // MARK: - State transitions

    private func handleStateChange(_ newState: CapsuleState) {
        switch newState {
        case .recording:
            recordingDuration = 0
            waveHistory = Array(repeating: 0, count: 16)
        case .transcribing:
            // Trigger 3-dot breathing animation
            dotScale = 1.0
        default:
            break
        }
    }
}

// MARK: - CapsuleWaveformView

/// Audio-driven waveform bars. Silent at rest (Departure 1).
/// Bars animate only when audioLevel > Motion.waveformActivationThreshold.
struct CapsuleWaveformView: View {
    let history: [Float]
    let level: Float

    private let barCount = 12
    private let barWidth: CGFloat = 2.5
    private let spacing: CGFloat = 1.5

    var body: some View {
        HStack(spacing: spacing) {
            ForEach(0..<barCount, id: \.self) { idx in
                let sampleIndex = max(0, history.count - barCount + idx)
                let rawValue = sampleIndex < history.count ? history[sampleIndex] : 0
                // Suppress bars below threshold — honest waveform (Departure 1)
                let isActive = Double(rawValue) > Motion.waveformActivationThreshold
                let barHeight: CGFloat = isActive ? max(4, CGFloat(rawValue) * (CapsuleSize.height * 0.55)) : 3

                RoundedRectangle(cornerRadius: 1)
                    .fill(Palette.Capsule.recording.opacity(isActive ? 0.85 : 0.25))
                    .frame(width: barWidth, height: barHeight)
                    .animation(.easeInOut(duration: 0.08), value: barHeight)
            }
        }
    }
}

// swiftlint:enable inline_color_rgb inline_color_hex inline_nscolor_rgb
