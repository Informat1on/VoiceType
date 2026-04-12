import SwiftUI

@main
struct VoiceTypeApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    var body: some Scene {
        MenuBarExtra {
            MenuBarView(hotkeyService: appDelegate.hotkeyService, appDelegate: appDelegate)
        } label: {
            Image(systemName: menuBarIcon)
                .foregroundColor(menuBarColor)
        }
    }

    private var menuBarIcon: String {
        switch appDelegate.appState {
        case .idle: return "waveform"
        case .recording: return "mic.fill"
        case .transcribing: return "text.bubble.fill"
        case .injecting: return "arrow.right.doc.on.clipboard.fill"
        }
    }

    private var menuBarColor: Color {
        switch appDelegate.appState {
        case .idle: return .primary
        case .recording: return .red
        case .transcribing: return .blue
        case .injecting: return .mint
        }
    }
}
