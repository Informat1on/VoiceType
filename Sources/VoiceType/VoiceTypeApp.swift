// VoiceTypeApp.swift
//
// Step 5: MenuBarExtra switched to .window style to support the custom 280pt
// SwiftUI layout in MenuBarView. Menubar icon is a single SF Symbol ("waveform")
// that stays the same shape at all times — color is the only signal:
//   • default (.primary / template) — idle, transcribing, injecting
//   • Palette.Capsule.recording (red) — recording
// DESIGN.md § Iconography: "template SF Symbol, same shape at all times".

import SwiftUI

@main
struct VoiceTypeApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    var body: some Scene {
        MenuBarExtra {
            MenuBarView(appDelegate: appDelegate)
        } label: {
            Image(systemName: "waveform")
                .foregroundStyle(menuBarIconColor)
        }
        .menuBarExtraStyle(.window)
    }

    /// Two-color icon: red during recording, system default otherwise.
    /// DESIGN.md § Iconography: "Color: default text/primary; red Capsule.recording when recording."
    private var menuBarIconColor: Color {
        appDelegate.appState == .recording ? Palette.Capsule.recording : .primary
    }
}
