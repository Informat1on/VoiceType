import AppKit
import SwiftUI

enum VoiceTypeState {
    case recording
    case processing
}

final class VoiceTypeWindow: NSWindow {
    private var hostingView: NSHostingView<VoiceTypeIndicatorView>?
    private let audioService: AudioCaptureService
    
    init(audioService: AudioCaptureService) {
        self.audioService = audioService
        
        let rect = NSRect(
            x: 0,
            y: 0,
            width: VoiceTypeIndicatorMetrics.totalWidth,
            height: VoiceTypeIndicatorMetrics.totalHeight
        )
        
        super.init(
            contentRect: rect,
            styleMask: [.borderless, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        
        configureWindow()
        setContent(state: .recording)
    }
    
    func show(state: VoiceTypeState) {
        setContent(state: state)
        positionAtTopCenter()
        orderFrontRegardless()
    }
    
    func hide() {
        orderOut(nil)
    }
    
    private func configureWindow() {
        backgroundColor = .clear
        isOpaque = false
        hasShadow = false
        level = .floating
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        ignoresMouseEvents = true
        animationBehavior = .none
    }
    
    private func positionAtTopCenter() {
        guard let screen = NSScreen.main else { return }
        let screenFrame = screen.frame
        let windowHeight = frame.height
        let topOffset: CGFloat = 80
        
        let x = screenFrame.midX - frame.width / 2
        let y = screenFrame.maxY - windowHeight - topOffset
        
        setFrameOrigin(NSPoint(x: x, y: y))
    }
    
    private func setContent(state: VoiceTypeState) {
        let indicatorView = VoiceTypeIndicatorView(
            state: state,
            audioService: audioService
        )
        let hosting = NSHostingView(rootView: indicatorView)
        hostingView = hosting
        contentView = hosting
    }
}
