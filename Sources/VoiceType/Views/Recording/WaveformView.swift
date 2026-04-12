import SwiftUI

enum VoiceTypeIndicatorMetrics {
    static let capsuleWidth: CGFloat = 240
    static let capsuleHeight: CGFloat = 48
    static let shadowPadding: CGFloat = 16
    static let totalWidth: CGFloat = capsuleWidth + shadowPadding * 2
    static let totalHeight: CGFloat = capsuleHeight + shadowPadding * 2
}

struct VoiceTypeIndicatorView: View {
    let state: VoiceTypeState
    @ObservedObject var audioService: AudioCaptureService
    @ObservedObject private var settings = AppSettings.shared
    @State private var recordingDuration: TimeInterval = 0
    @State private var history: [Float] = Array(repeating: 0, count: 32)
    @State private var rotation: Double = 0
    @State private var borderPhase: Double = 0
    @State private var dotPulse: Double = 0
    
    private let levelTimer = Timer.publish(every: 0.05, on: .main, in: .common).autoconnect()
    private let durationTimer = Timer.publish(every: 1, on: .main, in: .common).autoconnect()
    private let borderTimer = Timer.publish(every: 0.016, on: .main, in: .common).autoconnect()
    
    var body: some View {
        ZStack {
            ZStack {
                Capsule()
                    .fill(Color.black.opacity(0.35))

                Capsule()
                    .fill(.ultraThinMaterial)
                    .opacity(0.95)

                AnimatedCapsuleBorder(level: audioService.audioLevel, phase: borderPhase, isActive: state == .recording)

                Group {
                    switch state {
                    case .recording:
                        recordingContent
                            .transition(.opacity.combined(with: .scale(scale: 0.95)))
                    case .processing:
                        processingContent
                            .transition(.opacity.combined(with: .scale(scale: 0.95)))
                    }
                }
                .animation(.easeInOut(duration: 0.3), value: state)
                .padding(.horizontal, 18)
                .padding(.vertical, 14)
            }
            .frame(width: VoiceTypeIndicatorMetrics.capsuleWidth, height: VoiceTypeIndicatorMetrics.capsuleHeight)
            .shadow(color: .black.opacity(0.25), radius: 10, x: 0, y: 5)
            .shadow(color: .cyan.opacity(0.15), radius: 8, x: 0, y: 2)
        }
        .frame(width: VoiceTypeIndicatorMetrics.totalWidth, height: VoiceTypeIndicatorMetrics.totalHeight)
        .animation(.easeInOut(duration: 0.3), value: state)
        .onReceive(levelTimer) { _ in
            if state == .recording {
                history.append(audioService.audioLevel)
                if history.count > 32 {
                    history.removeFirst()
                }
            }
        }
        .onReceive(durationTimer) { _ in
            if state == .recording {
                recordingDuration += 1
            }
        }
        .onReceive(borderTimer) { _ in
            if state == .recording {
                borderPhase += 0.003
            }
        }
        .onAppear {
            if state == .recording {
                recordingDuration = 0
                history = Array(repeating: 0, count: 32)
                withAnimation(.linear(duration: 2).repeatForever(autoreverses: false)) {
                    dotPulse = 1
                }
            } else {
                withAnimation(.linear(duration: 1.0).repeatForever(autoreverses: false)) {
                    rotation = 360
                }
            }
        }
    }
    
    private var recordingContent: some View {
        HStack(spacing: 0) {
            switch settings.indicatorStyle {
            case .dot:
                PulsingDotView(level: audioService.audioLevel, pulse: dotPulse)
                    .frame(width: 14, alignment: .leading)
            case .waveform:
                MiniWaveformView(history: history, level: audioService.audioLevel)
                    .frame(width: 32, alignment: .leading)
            }
            
            Text("Recording")
                .font(.system(size: 13, weight: .semibold))
                .foregroundColor(.white)
                .padding(.leading, 10)
            
            Spacer(minLength: 16)
            
            Text(formattedDuration)
                .font(.system(size: 13, weight: .medium, design: .monospaced))
                .foregroundColor(.white.opacity(0.8))
                .frame(minWidth: 34, alignment: .trailing)
        }
    }
    
    private var processingContent: some View {
        HStack(spacing: 8) {
            ZStack {
                Circle()
                    .stroke(.white.opacity(0.25), lineWidth: 2)
                    .frame(width: 18, height: 18)
                
                Circle()
                    .trim(from: 0, to: 0.75)
                    .stroke(
                        LinearGradient(colors: [.blue, .purple], startPoint: .leading, endPoint: .trailing),
                        lineWidth: 2)
                    .frame(width: 18, height: 18)
                    .rotationEffect(.degrees(rotation))
                
                Image(systemName: "waveform")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundColor(.white)
            }
            
            Text("Processing")
                .font(.system(size: 13, weight: .semibold))
                .foregroundColor(.white)
        }
    }
    
    private var formattedDuration: String {
        let minutes = Int(recordingDuration) / 60
        let seconds = Int(recordingDuration) % 60
        return String(format: "%d:%02d", minutes, seconds)
    }
}

// MARK: - Animated Capsule Border

struct AnimatedCapsuleBorder: View {
    let level: Float
    let phase: Double
    let isActive: Bool
    
    var body: some View {
        let lineWidth = isActive ? 1.5 + CGFloat(level) * 1.5 : 1.0
        let opacity = isActive ? 0.5 + Double(level) * 0.5 : 0.3
        
        Capsule()
            .strokeBorder(
                AngularGradient(
                    gradient: Gradient(colors: [
                        .blue.opacity(opacity),
                        .cyan.opacity(opacity),
                        Color(red: 0.4, green: 0.4, blue: 1.0).opacity(opacity),
                        .purple.opacity(opacity * 0.8),
                        .blue.opacity(opacity)
                    ]),
                    center: .center,
                    angle: .degrees(phase * 360)
                ),
                lineWidth: lineWidth
            )
            .animation(.easeInOut(duration: 0.15), value: level)
    }
}

// MARK: - Pulsing Dot View

struct PulsingDotView: View {
    let level: Float
    let pulse: Double
    
    var body: some View {
        let scale = 1.0 + CGFloat(level) * 0.5
        let opacity = 0.6 + Double(level) * 0.4
        
        Circle()
            .fill(.cyan)
            .frame(width: 8, height: 8)
            .scaleEffect(scale)
            .opacity(opacity)
            .overlay(
                Circle()
                    .fill(.cyan.opacity(0.3))
                    .frame(width: 16, height: 16)
                    .scaleEffect(1.0 + pulse * CGFloat(level) * 0.8)
                    .opacity(0.3 - Double(level) * 0.2)
            )
    }
}

// MARK: - Mini Waveform Bars View

struct MiniWaveformView: View {
    let history: [Float]
    let level: Float
    
    var body: some View {
        HStack(spacing: 2) {
            ForEach(0..<8) { i in
                let sampleIndex = max(0, history.count - 8 + i)
                let value = sampleIndex < history.count ? history[sampleIndex] : 0
                let barHeight = 4 + CGFloat(value) * 14
                
                Capsule()
                    .fill(
                        LinearGradient(
                            colors: [.cyan, .blue],
                            startPoint: .bottom,
                            endPoint: .top
                        )
                    )
                    .frame(width: 3, height: barHeight)
                    .animation(.easeInOut(duration: 0.08), value: value)
            }
        }
        .frame(width: 32, height: 18)
    }
}
