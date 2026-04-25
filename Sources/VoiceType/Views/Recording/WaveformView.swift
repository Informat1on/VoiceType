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

    // Timer state — Date-based so value is always correct regardless of when
    // the timer subscriber started. Counter-style had a race where timer
    // fired before first user recording, making "first take" show stale N sec.
    @State private var recordingStartedAt: Date?
    @State private var frozenDuration: TimeInterval = 0
    @State private var tickTrigger: Int = 0
    private let tickTimer = Timer.publish(every: 0.25, on: .main, in: .common).autoconnect()

    // Waveform state (audio-driven, silent at rest per Departure 1)
    @State private var waveHistory: [Float] = Array(repeating: 0, count: 16)
    private let levelTimer = Timer.publish(every: 0.05, on: .main, in: .common).autoconnect()

    // Transcribing dot-breathing state. Removed unused `dotOffset` (P2-D).
    @State private var dotScale: CGFloat = 0.7

    // Tally dot pulse — audio-threshold-gated. Updated from levelTimer.
    @State private var tallyScale: CGFloat = 1.0

    // Reduced-motion branch (DESIGN.md § Reduced motion)
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// State-label transition: opacity+scale (default) or opacity-only (reduce motion).
    private var labelTransition: AnyTransition {
        reduceMotion ? .opacity : .opacity.combined(with: .scale(scale: 0.97))
    }

    /// Current recording duration in seconds, computed from startedAt anchor.
    /// Depends on `tickTrigger` so SwiftUI re-renders every tick.
    private var recordingDuration: TimeInterval {
        _ = tickTrigger  // force dep
        guard let start = recordingStartedAt else { return frozenDuration }
        return Date().timeIntervalSince(start)
    }

    var body: some View {
        ZStack {
            capsuleBody
        }
        .frame(width: VoiceTypeCapsuleMetrics.totalWidth, height: VoiceTypeCapsuleMetrics.totalHeight)
        .onReceive(levelTimer) { _ in
            guard state == .recording else { return }
            waveHistory.append(audioService.audioLevel)
            if waveHistory.count > 16 { waveHistory.removeFirst() }
            // Tally stays static — user prefers reactive waveform, not a
            // pulsing dot. Leave tallyScale at 1.0.
        }
        .onReceive(tickTimer) { _ in
            guard state == .recording else { return }
            tickTrigger &+= 1  // triggers recomputation of recordingDuration
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
            .transition(labelTransition)

        case .transcribing:
            threeZoneLayout(
                leading: { mutedTallyWithChip },
                center: {
                    // Dots only — no "TRANSCRIBING" text per A6
                    TranscribingDotsView(dotScale: dotScale)
                },
                trailing: { timerZone }
            )
            .transition(labelTransition)

        case let .inserted(charCount, appName):
            threeZoneLayout(
                leading: {
                    HStack(spacing: 8) {
                        InsertedTallyView()
                        langChip
                    }
                },
                center: {
                    Text("Inserted \u{00B7} \(charCount) chars \u{2192} \(appName)")
                        .font(Typography.metaLabel)
                        .foregroundStyle(Palette.Capsule.text)
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                },
                trailing: { timerZone }
            )
            .transition(labelTransition)

        case let .errorInline(message):
            threeZoneLayout(
                leading: { errorTallyWithChip },
                center: {
                    // Error message in red per v3-states-atlas `.err-text { color: #FF7A6B }`.
                    Text(message)
                        .font(Typography.metaLabel)
                        .foregroundStyle(Palette.error)
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                },
                trailing: { timerZone }
            )
            .transition(labelTransition)

        case let .errorToast(title, _):
            // TODO: Step 7 — render as separate toast NSWindow.
            // For now: mirror errorInline treatment (tally + chip + red text).
            threeZoneLayout(
                leading: { errorTallyWithChip },
                center: {
                    Text(title)
                        .font(Typography.metaLabel)
                        .foregroundStyle(Palette.error)
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                },
                trailing: {
                    Text("")
                        .font(Typography.mono)
                        .frame(minWidth: 30, alignment: .trailing)
                }
            )
            .transition(labelTransition)

        case .emptyResult:
            threeZoneLayout(
                leading: { mutedTallyWithChip },
                center: {
                    Text("Nothing heard")
                        .font(Typography.metaLabel)
                        .foregroundStyle(Palette.Capsule.timer)
                        .lineLimit(1)
                },
                trailing: { timerZone }
            )
            .transition(labelTransition)
        }
    }

    // MARK: - Zone-left helpers (lang-chip present in ALL states per prototype)

    /// `<tally> + <lang-chip>` — prototype shows both in every state's zone-left.
    /// Recording uses leadingZone (adds REC label); the helpers below cover the
    /// remaining 5 states with the correct tally color.
    private var mutedTallyWithChip: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(Palette.Capsule.timer)
                .frame(width: MenuBar.tallyDotSize, height: MenuBar.tallyDotSize)
            langChip
        }
    }

    private var errorTallyWithChip: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(Palette.error)
                .frame(width: MenuBar.tallyDotSize, height: MenuBar.tallyDotSize)
            langChip
        }
    }

    /// Flat lang-chip — Geist Mono 10pt Medium, capsule-text cream, 0.6pt tracking.
    /// Prototype `.lang-chip { font-size: 10px; font-weight: 500; letter-spacing: 0.06em }`.
    private var langChip: some View {
        Text(chipLabel)
            .font(Typography.badge)
            .foregroundStyle(Palette.Capsule.text)
            .tracking(0.6)
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
            recordingStartedAt = Date()          // timer anchor
            frozenDuration = 0
            tickTrigger = 0
            waveHistory = Array(repeating: 0, count: 16)
            dotScale = 0.7  // reset for next transcribing entry (P2-E)
            tallyScale = 1.0
        case .transcribing:
            // Freeze timer display at final recording duration.
            if let start = recordingStartedAt {
                frozenDuration = Date().timeIntervalSince(start)
            }
            recordingStartedAt = nil
            // Trigger 3-dot breathing animation. Reset-then-set so re-entry
            // from a prior transcribing cycle fires the animation again.
            dotScale = 0.5
            DispatchQueue.main.async { dotScale = 1.3 }
        default:
            dotScale = 0.7
            recordingStartedAt = nil
            frozenDuration = 0
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

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private let barCount = 5
    private let barWidth: CGFloat = 3
    private let spacing: CGFloat = 2
    private let maxHeight: CGFloat = 20

    /// Prototype active bar heights: tall-peaked pattern mimicking waveform.
    private let activeHeights: [CGFloat] = [8, 14, 18, 12, 6]

    var body: some View {
        // Each bar reads its OWN sample from the tail of history → running
        // waveform. Bar height = activeHeights[idx] × normalized amplitude,
        // so the prototype arc contour (tallest in middle, shorter on edges)
        // is preserved while amplitude drives vertical motion per bar.
        // Found by codex review P2-1: previously `sample × maxHeight` ignored
        // the activeHeights array, collapsing all bars to the same height.
        let tail = history.suffix(barCount)
        let samples: [Float] = Array(repeating: 0, count: max(0, barCount - tail.count)) + Array(tail)
        let recentPeak = samples.max() ?? 0
        let isLoud = Double(recentPeak) >= Motion.waveformActivationThreshold

        HStack(spacing: spacing) {
            ForEach(0..<barCount, id: \.self) { idx in
                let sample = CGFloat(samples[idx])
                // Typical speech audioLevel 0.03-0.20 → amplified 0.24-1.6
                // clamped 0-1. Floor 0.25 so even quiet speech shows some arc.
                let amplified = min(1.0, max(0.25, sample * 8.0))
                // Prototype height × live amplitude → arc shape preserved,
                // amplitude drives motion. Silent: flat 4pt per prototype.
                let contouredHeight = activeHeights[idx] * amplified
                let barHeight: CGFloat = isLoud ? max(4, contouredHeight) : 4

                RoundedRectangle(cornerRadius: 1)
                    .fill(isLoud
                        ? Palette.Capsule.text
                        : Palette.Capsule.timer.opacity(0.55))
                    .frame(width: barWidth, height: barHeight)
                    .animation(reduceMotion ? nil : .easeInOut(duration: 0.05), value: barHeight)
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
///
/// Reduced motion (DESIGN.md § Reduced motion): scale pulse replaced with
/// opacity fade so no geometric movement occurs.
private struct TranscribingDotsView: View {
    let dotScale: CGFloat

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        HStack(spacing: 3) {
            ForEach(0..<3, id: \.self) { idx in
                Circle()
                    .fill(Palette.Capsule.timer)
                    .frame(width: 4, height: 4)
                    .modifier(BreathingMod(value: dotScale, idx: idx, reduceMotion: reduceMotion))
            }
        }
    }
}

/// Applies breathing animation to a dot — scale pulse (default) or opacity
/// fade (reduce motion). Both share the same timing and delay values.
/// `internal` (not `private`) so ReducedMotionTests can exercise opacityFromScale.
struct BreathingMod: ViewModifier {
    let value: CGFloat
    let idx: Int
    let reduceMotion: Bool

    func body(content: Content) -> some View {
        let anim = Animation.easeInOut(duration: Motion.long)
            .repeatForever(autoreverses: true)
            .delay(Double(idx) * Motion.long / 3.0)

        if reduceMotion {
            // Opacity-only fade: map dotScale 0.5..1.3 → opacity 0.4..1.0
            content
                .opacity(opacityFromScale(value))
                .animation(anim, value: value)
        } else {
            content
                .scaleEffect(value)
                .animation(anim, value: value)
        }
    }

    /// Maps dotScale (0.5 … 1.3) to opacity (0.4 … 1.0), clamped.
    /// Internal: exposed via `internal` so ReducedMotionTests can exercise it.
    func opacityFromScale(_ scale: CGFloat) -> Double {
        let normalized = (Double(scale) - 0.5) / 0.8   // 0.5→0.0, 1.3→1.0
        return max(0.4, min(1.0, 0.4 + 0.6 * normalized))
    }
}

// MARK: - Notification name (A7)

extension Notification.Name {
    /// Posted by CapsuleStateModel after 4s in .errorInline.
    /// AppDelegate subscribes to call voiceTypeWindow?.hide() (Phase 2 wiring).
    static let capsuleErrorInlineExpired = Notification.Name("com.voicetype.capsuleErrorInlineExpired")
}
