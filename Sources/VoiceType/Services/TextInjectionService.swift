import Cocoa

final class TextInjectionService {

    enum TextInjectionError: Error, LocalizedError {
        case pasteFailed
        case missingAccessibilityPermission

        var errorDescription: String? {
            switch self {
            case .pasteFailed:
                return "Failed to paste text. Ensure Accessibility permissions are granted."
            case .missingAccessibilityPermission:
                return "Accessibility permission is required to insert text. If you just enabled it in System Settings, relaunch VoiceType from ~/Applications and try again."
            }
        }
    }

    private let eventSource: CGEventSource?

    init() {
        self.eventSource = CGEventSource(stateID: .hidSystemState)
    }

    func injectText(_ text: String, mode: TextInjectionMode, pressEnterAfter: Bool = true) throws {
        guard !text.isEmpty else { return }

        guard Self.hasAccessibilityPermissions() else {
            throw TextInjectionError.missingAccessibilityPermission
        }

        switch mode {
        case .paste:
            try injectViaPaste(text, pressEnterAfter: pressEnterAfter)
        case .type:
            try injectViaTyping(text, pressEnterAfter: pressEnterAfter)
        }
    }

    private func injectViaPaste(_ text: String, pressEnterAfter: Bool) throws {
        let pasteboard = NSPasteboard.general
        let savedItems = pasteboard.pasteboardItems

        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)

        let success = simulatePaste()
        usleep(100_000)

        if pressEnterAfter, let eventSource {
            pressEnter(eventSource: eventSource)
        }

        if let savedItems, !savedItems.isEmpty {
            pasteboard.clearContents()
            for item in savedItems {
                pasteboard.writeObjects([item])
            }
        } else {
            pasteboard.clearContents()
        }

        if !success {
            throw TextInjectionError.pasteFailed
        }
    }

    private func injectViaTyping(_ text: String, pressEnterAfter: Bool) throws {
        guard let eventSource else {
            throw TextInjectionError.pasteFailed
        }

        for char in text {
            typeCharacter(char, eventSource: eventSource)
            usleep(2_000)
        }

        if pressEnterAfter {
            pressEnter(eventSource: eventSource)
        }
    }

    private func typeCharacter(_ character: Character, eventSource: CGEventSource) {
        let unichars = Array(String(character).utf16)

        guard let keyDown = CGEvent(keyboardEventSource: eventSource, virtualKey: 0, keyDown: true),
              let keyUp = CGEvent(keyboardEventSource: eventSource, virtualKey: 0, keyDown: false) else {
            return
        }

        keyDown.keyboardSetUnicodeString(stringLength: unichars.count, unicodeString: unichars)
        keyUp.keyboardSetUnicodeString(stringLength: unichars.count, unicodeString: unichars)

        keyDown.post(tap: .cghidEventTap)
        keyUp.post(tap: .cghidEventTap)
    }

    private func simulatePaste() -> Bool {
        guard let eventSource else { return false }

        let kVK_Command: CGKeyCode = 0x37
        let kVK_V: CGKeyCode = 0x09

        let commandDown = CGEvent(keyboardEventSource: eventSource, virtualKey: kVK_Command, keyDown: true)
        let vDown = CGEvent(keyboardEventSource: eventSource, virtualKey: kVK_V, keyDown: true)
        let vUp = CGEvent(keyboardEventSource: eventSource, virtualKey: kVK_V, keyDown: false)
        let commandUp = CGEvent(keyboardEventSource: eventSource, virtualKey: kVK_Command, keyDown: false)

        guard let commandDown, let vDown, let vUp, let commandUp else {
            return false
        }

        vDown.flags = .maskCommand
        vUp.flags = .maskCommand

        commandDown.post(tap: .cghidEventTap)
        usleep(5_000)
        vDown.post(tap: .cghidEventTap)
        usleep(5_000)
        vUp.post(tap: .cghidEventTap)
        usleep(5_000)
        commandUp.post(tap: .cghidEventTap)

        return true
    }

    private func pressEnter(eventSource: CGEventSource) {
        let kVK_Return: CGKeyCode = 0x24

        guard
            let keyDown = CGEvent(keyboardEventSource: eventSource, virtualKey: kVK_Return, keyDown: true),
            let keyUp = CGEvent(keyboardEventSource: eventSource, virtualKey: kVK_Return, keyDown: false)
        else { return }

        keyDown.post(tap: .cghidEventTap)
        usleep(5_000)
        keyUp.post(tap: .cghidEventTap)
    }

    static func hasAccessibilityPermissions() -> Bool {
        let options: [String: Any] = [kAXTrustedCheckOptionPrompt.takeRetainedValue() as String: false]
        return AXIsProcessTrustedWithOptions(options as CFDictionary)
    }

    static func requestAccessibilityPermissions() {
        let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!
        NSWorkspace.shared.open(url)
    }
}
