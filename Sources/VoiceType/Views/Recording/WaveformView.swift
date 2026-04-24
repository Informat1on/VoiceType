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
            // Background — opaque dark per DESIGN.md (no glassmorphism material)
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
        // Base shadow always on; colored glow only when state warrants it.
        // Red glow bleeding into inserted/error/empty states was a visual bug
        // found by code review P2-C.
        .shadow(color: Color.black.opacity(0.50), radius: 4, x: 0, y: 2)
        .shadow(color: glowColor, radius: 8, x: 0, y: 0)
        .animation(.easeInOut(duration: Motion.short), value: state)
    }

    // MARK: - Border color per state

    private var borderColor: Color {
        switch state {
        case .recording:                return Palette.Capsule.borderRec
        case .errorInline, .errorToast: return Palette.Capsule.borderErr
        case .inserted:                 return Palette.Capsule.borderOk
        default:                        return Palette.Capsule.borderIdle
        }
    }

    /// Ambient glow — state-specific per HTML prototype atlas.
    /// Recording = red (active mic). Inserted = green (success). Error = red-pink.
    /// Transcribing/emptyResult = no glow. Found by code review P2-C.
    private var glowColor: Color {
        switch state {
        case .recording:                return Palette.Capsule.recordingGlow
        case .inserted:                 return Palette.success.opacity(0.30)
        case .errorInline, .errorToast: return Palette.Capsule.borderErr.opacity(0.60)
        default:                        return Color.clear
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
            centeredLabel(
                "Inserted \u{00B7} \(charCount) chars \u{2192} \(appName)",
                color: Palette.success
            )
            .transition(.opacity.combined(with: .scale(scale: 0.97)))
        case let .errorInline(message):
            centeredLabel(message, color: Palette.Capsule.borderErr)
                .transition(.opacity.combined(with: .scale(scale: 0.97)))
        case let .errorToast(title, _):
            // TODO: Step 7 — render as separate toast NSWindow.
            // For now: inline error treatment.
            centeredLabel(title, color: Palette.Capsule.borderErr)
                .transition(.opacity.combined(with: .scale(scale: 0.97)))
        case .emptyResult:
            centeredLabel("Nothing heard", color: Palette.Capsule.timer)
                .transition(.opacity.combined(with: .scale(scale: 0.97)))
        }
    }

    // MARK: - Recording: three zones

    private var recordingZones: some View {
        // Prototype: zone-left flex-shrink:0, zone-center flex:1 (fills remaining
        // space, centered content), zone-right flex-shrink:0. Gap 12 between zones.
        HStack(spacing: 12) {
            // Zone 1 — leading: tally + lang-chip (NO "REC" text per prototype).
            leadingZone

            // Zone 2 — center: audio waveform, flex-fill centered
            waveformZone
                .frame(maxWidth: .infinity)

            // Zone 3 — trailing: MM:SS timer
            timerZone
        }
    }

    // MARK: Zone 1: leading

    private var leadingZone: some View {
        // Prototype spec: 8px gap, 8px tally + flat lang-chip text (NO border, NO REC).
        HStack(spacing: 8) {
            Circle()
                .fill(Palette.Capsule.recording)
                .frame(width: MenuBar.tallyDotSize, height: MenuBar.tallyDotSize)
                .scaleEffect(tallyScale)

            // Flat lang-chip — Geist Mono 10pt Medium, capsule.text color, no border.
            Text(chipLabel)
                .font(Typography.badge)
                .foregroundStyle(Palette.Capsule.text)
                .tracking(0.6)   // 0.06em × 10pt = 0.6
        }
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

    /// Accepts an explicit `color` so state-specific colors (success green,
    /// error red, muted cream for emptyResult) actually propagate. An
    /// unconditional `.foregroundStyle` on the inner Text would be dead code —
    /// SwiftUI does NOT inherit foregroundStyle from parent containers when
    /// the child Text already has one set. Found by code review P1-A.
    private func centeredLabel(_ text: String, color: Color = Palette.Capsule.text) -> some View {
        HStack {
            Spacer()
            Text(text)
                .font(Typography.metaLabel)
                .foregroundStyle(color)
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

/// Audio-driven waveform bars. Matches prototype v1-cool-inksteel CSS spec:
/// - 5 bars, 3×20pt each, 2pt gap (was 12 bars — cluttered)
/// - Silent: all bars 4pt tall, muted timer color
/// - Active: bars follow level via spec heights pattern [8/14/18/12/6]
///   scaled by recent audio-level peak, cream capsule.text color
struct CapsuleWaveformView: View {
    let history: [Float]
    let level: Float

    private let barCount = 5
    private let barWidth: CGFloat = 3
    private let spacing: CGFloat = 2
    private let maxHeight: CGFloat = 20

    /// Prototype active bar heights: tall-peaked pattern mimicking waveform.
    private let activeHeights: [CGFloat] = [8, 14, 18, 12, 6]

    var body: some View {
        let recentPeak = max(level, history.suffix(4).max() ?? 0)
        let isActive = Double(recentPeak) > Motion.waveformActivationThreshold

        HStack(spacing: spacing) {
            ForEach(0..<barCount, id: \.self) { idx in
                // Active: spec heights × normalized peak (min 50% so bars
                // don't collapse at low level). Silent: flat 4pt.
                let scale = CGFloat(recentPeak)
                let activeH = activeHeights[idx] * max(0.5, min(1.0, scale * 2.5))
                let barHeight: CGFloat = isActive ? max(4, activeH) : 4

                RoundedRectangle(cornerRadius: 1)
                    .fill(isActive
                        ? Palette.Capsule.text
                        : Palette.Capsule.timer.opacity(0.40))
                    .frame(width: barWidth, height: barHeight)
                    .animation(.easeInOut(duration: 0.08), value: barHeight)
            }
        }
        .frame(height: maxHeight)
    }
}
