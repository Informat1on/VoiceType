import SwiftUI

struct MenuBarView: View {
    @ObservedObject private var hotkeyService: HotkeyService
    private weak var appDelegate: AppDelegate?

    init(hotkeyService: HotkeyService, appDelegate: AppDelegate) {
        self.hotkeyService = hotkeyService
        self.appDelegate = appDelegate
    }

    var body: some View {
        Button {
            openSettings()
        } label: {
            Label("Settings", systemImage: "gearshape")
        }

        Divider()

        Button {
            appDelegate?.openAbout()
        } label: {
            Label("About VoiceType", systemImage: "info.circle")
        }

        Divider()

        Button {
            NSApp.terminate(nil)
        } label: {
            Label("Quit VoiceType", systemImage: "xmark.circle")
        }
        .keyboardShortcut("q", modifiers: .command)
    }
    
    private func openSettings() {
        print("[MenuBarView] openSettings() called")
        appDelegate?.openSettings()
    }
}
