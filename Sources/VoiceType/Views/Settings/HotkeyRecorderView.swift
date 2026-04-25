// HotkeyRecorderView.swift — VoiceType
//
// NSViewRepresentable wrapper that captures a key event for hotkey assignment.
// Extracted from SettingsView.swift (Chunk T). Module-internal.
//
// Prototype source of truth: v1-cool-inksteel.html.
// DESIGN.md § Interaction States / Shortcuts tab.

import SwiftUI
import AppKit

// MARK: - Hotkey Recorder View (preserved verbatim — do NOT modify)

struct HotkeyRecorderView: View {
    @Binding var isRecording: Bool
    @Binding var recordedModifiers: Int
    @Binding var recordedKey: Int

    var body: some View {
        HotkeyRecorderRepresentable(
            isRecording: $isRecording,
            recordedModifiers: $recordedModifiers,
            recordedKey: $recordedKey
        )
    }
}

struct HotkeyRecorderRepresentable: NSViewRepresentable {
    @Binding var isRecording: Bool
    @Binding var recordedModifiers: Int
    @Binding var recordedKey: Int

    final class Coordinator {
        var monitor: Any?
    }

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        context.coordinator.monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            guard isRecording else { return event }

            var carbonModifiers = 0
            if event.modifierFlags.contains(.command) { carbonModifiers |= cmdKey }
            if event.modifierFlags.contains(.option) { carbonModifiers |= optionKey }
            if event.modifierFlags.contains(.shift) { carbonModifiers |= shiftKey }
            if event.modifierFlags.contains(.control) { carbonModifiers |= controlKey }

            recordedModifiers = carbonModifiers
            recordedKey = Int(event.keyCode)
            isRecording = false
            AppSettings.shared.hotkeyModifiers = recordedModifiers
            AppSettings.shared.hotkeyKey = recordedKey

            print("[HotkeyRecorder] Recorded: modifiers=\(carbonModifiers) (\(modifiersToString(carbonModifiers))), keyCode=\(recordedKey) (\(keyCodeToString(recordedKey)))")
            return nil
        }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {}

    static func dismantleNSView(_ nsView: NSView, coordinator: Coordinator) {
        if let monitor = coordinator.monitor {
            NSEvent.removeMonitor(monitor)
            coordinator.monitor = nil
        }
    }
}
