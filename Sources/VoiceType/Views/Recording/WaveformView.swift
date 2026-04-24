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
            // A7: schedule auto-dismiss when entering errorInline.
            // CapsuleStateModel posts .capsuleErrorInlineExpired after 4s;
            // AppDelegate subscribes to call voiceTypeWindow?.hide() (Phase 2).
            .onChange(of: stateModel.state) { newState in
                if case .errorInline = newState {
                    stateModel.scheduleErrorInlineDismiss()
                }
            }
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
            RoundedRectangle(cornerRadius: Radius.capsule)
                .fill(Palette.Capsule.bg)

            // Border — state-specific
            RoundedRectangle(cornerRadius: Radius.capsule)
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

    // MARK: - Content per state (3-zone layout for all states per A4)

    @ViewBuilder
    private var capsuleContent: some View {
        switch state {
        case .recording:
            threeZoneLayout(
                leading: { leadingZone },
                center: { waveformZone },
                trailing: { timerZone }
            )
            .transition(.opacity.combined(with: .scale(scale: 0.97)))

        case .transcribing:
            threeZoneLayout(
                leading: {
                    // Muted 8pt tally
                    Circle()
                        .fill(Palette.Capsule.timer)
                        .frame(width: MenuBar.tallyDotSize, height: MenuBar.tallyDotSize)
                },
                center: {
                    // Dots only — no "TRANSCRIBING" text per A6
                    TranscribingDotsView(dotScale: dotScale)
                },
                trailing: { timerZone }
            )
            .transition(.opacity.combined(with: .scale(scale: 0.97)))

        case let .inserted(charCount, appName):
            threeZoneLayout(
                leading: { InsertedTallyView() },
                center: {
                    Text("Inserted \u{00B7} \(charCount) chars \u{2192} \(appName)")
                        .font(Typography.metaLabel)
                        .foregroundStyle(Palette.Capsule.text)
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                },
                trailing: { timerZone }
            )
            .transition(.opacity.combined(with: .scale(scale: 0.97)))

        case let .errorInline(message):
            threeZoneLayout(
                leading: {
                    Circle()
                        .fill(Palette.error)
                        .frame(width: MenuBar.tallyDotSize, height: MenuBar.tallyDotSize)
                },
                center: {
                    // Message in cream (NOT red) per A4 spec
                    Text(message)
                        .font(Typography.metaLabel)
                        .foregroundStyle(Palette.Capsule.text)
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                },
                trailing: { timerZone }
            )
            .transition(.opacity.combined(with: .scale(scale: 0.97)))

        case let .errorToast(title, _):
            // TODO: Step 7 — render as separate toast NSWindow.
            // For now: mirror errorInline treatment per A4.
            threeZoneLayout(
                leading: {
                    Circle()
                        .fill(Palette.error)
                        .frame(width: MenuBar.tallyDotSize, height: MenuBar.tallyDotSize)
                },
                center: {
                    Text(title)
                        .font(Typography.metaLabel)
                        .foregroundStyle(Palette.Capsule.text)
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                },
                trailing: {
                    Text("")
                        .font(Typography.mono)
                        .frame(minWidth: 30, alignment: .trailing)
                }
            )
            .transition(.opacity.combined(with: .scale(scale: 0.97)))

        case .emptyResult:
            threeZoneLayout(
                leading: {
                    Circle()
                        .fill(Palette.Capsule.timer)
                        .frame(width: MenuBar.tallyDotSize, height: MenuBar.tallyDotSize)
                },
                center: {
                    Text("Nothing heard")
                        .font(Typography.metaLabel)
                        .foregroundStyle(Palette.Capsule.timer)
                        .lineLimit(1)
                },
                trailing: { timerZone }
            )
            .transition(.opacity.combined(with: .scale(scale: 0.97)))
        }
    }

    // MARK: - Three-zone layout helper (A4)

    private func threeZoneLayout<L: View, C: View, T: View>(
        @ViewBuilder leading: () -> L,
        @ViewBuilder center: () -> C,
        @ViewBuilder trailing: () -> T
    ) -> some View {
        HStack(spacing: 12) {
            leading()
            center().frame(maxWidth: .infinity)
            trailing()
        }
    }

    // MARK: Zone 1: leading

    private var leadingZone: some View {
        // Prototype spec: 8px gap, 8px tally + REC label + flat lang-chip text.
        // v6-a11y.html and DESIGN.md confirm REC is required as colorblind secondary signal.
        HStack(spacing: 8) {
            Circle()
                .fill(Palette.Capsule.recording)
                .frame(width: MenuBar.tallyDotSize, height: MenuBar.tallyDotSize)
                .scaleEffect(tallyScale)

            Text("REC")
                .font(Typography.badge)  // Geist Mono 10pt medium
                .foregroundStyle(Palette.Capsule.recording)
                .textCase(.uppercase)
                .tracking(0.8)  // 0.08em × 10pt = 0.8pt exact match

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
        CapsuleWaveformView(history: waveHistory)
            .frame(width: 60, height: 20)
    }

    // MARK: Zone 3: timer

    private var timerZone: some View {
        Text(formattedDuration)
            .font(Typography.mono)
            .foregroundStyle(state == .recording ? Palette.Capsule.text : Palette.Capsule.timer)
            .monospacedDigit()
            .frame(minWidth: 30, alignment: .trailing)
    }

    private var formattedDuration: String {
        let total = max(0, Int(recordingDuration))
        let minutes = total / 60
        let seconds = total % 60
        return String(format: "%d:%02d", minutes, seconds)
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
/// A8: `level` parameter removed — redundant since history already includes live level.
struct CapsuleWaveformView: View {
    let history: [Float]

    private let barCount = 5
    private let barWidth: CGFloat = 3
    private let spacing: CGFloat = 2
    private let maxHeight: CGFloat = 20

    /// Prototype active bar heights: tall-peaked pattern mimicking waveform.
    private let activeHeights: [CGFloat] = [8, 14, 18, 12, 6]

    var body: some View {
        let recentPeak = history.suffix(4).max() ?? 0
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

// MARK: - InsertedTallyView (A5)

/// 14pt green circle with "✓" checkmark for the inserted state zone-left.
/// Prototype CSS: .tally.inserted { background: var(--success); width: 14px; height: 14px; }
private struct InsertedTallyView: View {
    var body: some View {
        ZStack {
            Circle()
                .fill(Palette.success)
                .frame(width: 14, height: 14)
            Text("\u{2713}")  // ✓
                .font(.system(size: 10, weight: .bold))
                .foregroundStyle(Palette.Capsule.bg)
        }
    }
}

// MARK: - TranscribingDotsView (A6)

/// Three breathing dots for the transcribing state center zone.
/// Prototype CSS: .transcribing-dots .dot { width: 4px; height: 4px; gap: 3px; }
/// No "TRANSCRIBING" text — dots only, centered, 500ms breathing cycle.
private struct TranscribingDotsView: View {
    let dotScale: CGFloat

    var body: some View {
        HStack(spacing: 3) {
            ForEach(0..<3, id: \.self) { idx in
                Circle()
                    .fill(Palette.Capsule.timer)
                    .frame(width: 4, height: 4)
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

// MARK: - Notification name (A7)

extension Notification.Name {
    /// Posted by CapsuleStateModel after 4s in .errorInline.
    /// AppDelegate subscribes to call voiceTypeWindow?.hide() (Phase 2 wiring).
    static let capsuleErrorInlineExpired = Notification.Name("com.voicetype.capsuleErrorInlineExpired")
}
