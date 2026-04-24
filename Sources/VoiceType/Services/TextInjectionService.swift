import Cocoa
import Carbon
// TODO: TextInjectionService.insertText must honor settings.trimWhitespaceAfterInsert
// (AppSettings.shared.trimWhitespaceAfterInsert). Wiring deferred to a future Services step.

struct KeyboardKeystroke: Equatable {
    let keyCode: CGKeyCode
    let flags: CGEventFlags
}

final class KeyboardLayoutKeyResolver {
    private static let directKeystrokes: [Character: KeyboardKeystroke] = [
        " ": KeyboardKeystroke(keyCode: 0x31, flags: []),
        "\t": KeyboardKeystroke(keyCode: 0x30, flags: []),
        "\n": KeyboardKeystroke(keyCode: 0x24, flags: []),
        "\r": KeyboardKeystroke(keyCode: 0x24, flags: [])
    ]

    private static let lookupModifiers: [UInt32] = [
        0,
        UInt32(shiftKey),
        UInt32(optionKey),
        UInt32(shiftKey | optionKey)
    ]

    private var cache: [Character: KeyboardKeystroke] = [:]

    func keystrokes(for text: String) -> [KeyboardKeystroke]? {
        var keystrokes: [KeyboardKeystroke] = []
        keystrokes.reserveCapacity(text.count)

        for character in text {
            guard let keystroke = keystroke(for: character) else {
                return nil
            }

            keystrokes.append(keystroke)
        }

        return keystrokes
    }

    func keystroke(for character: Character) -> KeyboardKeystroke? {
        if let cached = cache[character] {
            return cached
        }

        if let directKeystroke = Self.directKeystrokes[character] {
            cache[character] = directKeystroke
            return directKeystroke
        }

        let target = String(character)
        guard !target.isEmpty,
              let source = TISCopyCurrentKeyboardLayoutInputSource()?.takeRetainedValue(),
              let rawLayoutData = TISGetInputSourceProperty(source, kTISPropertyUnicodeKeyLayoutData)
        else {
            return nil
        }

        let layoutData = unsafeBitCast(rawLayoutData, to: CFData.self)
        guard let layoutBytes = CFDataGetBytePtr(layoutData) else {
            return nil
        }

        let keyboardLayout = layoutBytes.withMemoryRebound(to: UCKeyboardLayout.self, capacity: 1) { $0 }

        for keyCode in 0..<128 {
            for modifiers in Self.lookupModifiers {
                guard translatedString(for: UInt16(keyCode), modifiers: modifiers, keyboardLayout: keyboardLayout) == target else {
                    continue
                }

                let keystroke = KeyboardKeystroke(
                    keyCode: CGKeyCode(keyCode),
                    flags: eventFlags(for: modifiers)
                )
                cache[character] = keystroke
                return keystroke
            }
        }

        return nil
    }

    private func translatedString(
        for keyCode: UInt16,
        modifiers: UInt32,
        keyboardLayout: UnsafePointer<UCKeyboardLayout>
    ) -> String? {
        var deadKeyState: UInt32 = 0
        var actualLength = 0
        var characters = [UniChar](repeating: 0, count: 4)

        let status = UCKeyTranslate(
            keyboardLayout,
            keyCode,
            UInt16(kUCKeyActionDown),
            modifiers >> 8,
            UInt32(LMGetKbdType()),
            OptionBits(kUCKeyTranslateNoDeadKeysBit),
            &deadKeyState,
            characters.count,
            &actualLength,
            &characters
        )

        guard status == noErr, actualLength > 0 else {
            return nil
        }

        return String(utf16CodeUnits: characters, count: actualLength)
    }

    private func eventFlags(for modifiers: UInt32) -> CGEventFlags {
        var flags: CGEventFlags = []

        if modifiers & UInt32(shiftKey) != 0 {
            flags.insert(.maskShift)
        }

        if modifiers & UInt32(optionKey) != 0 {
            flags.insert(.maskAlternate)
        }

        return flags
    }
}

final class TextInjectionService {
    private static let virtualKeyPressDelayMicroseconds: useconds_t = 5_000
    private static let unicodeKeyPressDelayMicroseconds: useconds_t = 5_000
    private static let typingInterEventDelayMicroseconds: useconds_t = 2_000

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
    private let keyResolver = KeyboardLayoutKeyResolver()

    init() {
        self.eventSource = CGEventSource(stateID: .hidSystemState)
    }

    func injectText(_ text: String, mode: TextInjectionMode, pressEnterAfter: Bool = true) throws {
        guard !text.isEmpty else { return }

        guard Self.hasAccessibilityPermissions() else {
            AppLog.insertion.error("Blocked text insertion because Accessibility is missing")
            throw TextInjectionError.missingAccessibilityPermission
        }

        switch effectiveInjectionMode(for: mode) {
        case .paste:
            try injectViaPaste(text, pressEnterAfter: pressEnterAfter)
        case .type:
            try injectViaTyping(text, pressEnterAfter: pressEnterAfter)
        }
    }

    func effectiveInjectionMode(for requestedMode: TextInjectionMode) -> TextInjectionMode {
        Self.effectiveInjectionMode(
            for: requestedMode,
            frontmostBundleIdentifier: NSWorkspace.shared.frontmostApplication?.bundleIdentifier,
            localizedName: NSWorkspace.shared.frontmostApplication?.localizedName
        )
    }

    static func effectiveInjectionMode(
        for requestedMode: TextInjectionMode,
        frontmostBundleIdentifier: String?,
        localizedName: String?
    ) -> TextInjectionMode {
        guard requestedMode == .type else {
            return requestedMode
        }

        // Claude Code is unreliable with simulated CGEvent typing for mixed Unicode text.
        // Route through paste there, while keeping the fast typing path everywhere else.
        if looksLikeClaudeCode(bundleIdentifier: frontmostBundleIdentifier, localizedName: localizedName) {
            return .paste
        }

        return .type
    }

    private func injectViaPaste(_ text: String, pressEnterAfter: Bool) throws {
        let pasteboard = NSPasteboard.general
        // Save only the string content — NSPasteboardItem objects are proxies
        // to the pasteboard's internal state and become invalid after clearContents().
        // Complex types (files, images, rich text) cannot be reliably restored.
        let savedString = pasteboard.string(forType: .string)

        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)

        let success = simulatePaste()
        usleep(100_000)

        if pressEnterAfter, let eventSource {
            pressEnter(eventSource: eventSource)
        }

        // Restore saved string content only
        if let savedString {
            pasteboard.clearContents()
            pasteboard.setString(savedString, forType: .string)
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

        for character in text {
            typeCharacter(character, eventSource: eventSource)
            usleep(Self.typingInterEventDelayMicroseconds)
        }

        if pressEnterAfter {
            pressEnter(eventSource: eventSource)
        }
    }

    private func typeCharacter(_ character: Character, eventSource: CGEventSource) {
        if let keystroke = keyResolver.keystroke(for: character) {
            typeCharacterWithVirtualKey(keystroke, eventSource: eventSource)
        } else {
            typeCharacterWithUnicode(String(character), eventSource: eventSource)
        }
    }

    /// Type a character using a real keyboard keystroke from the active layout.
    private func typeCharacterWithVirtualKey(_ keystroke: KeyboardKeystroke, eventSource: CGEventSource) {
        let modifierKeyCodes = modifierKeyCodes(for: keystroke.flags)

        for modifierKeyCode in modifierKeyCodes {
            postModifierEvent(keyCode: modifierKeyCode, keyDown: true, eventSource: eventSource)
        }

        guard let keyDown = CGEvent(keyboardEventSource: eventSource, virtualKey: keystroke.keyCode, keyDown: true),
              let keyUp = CGEvent(keyboardEventSource: eventSource, virtualKey: keystroke.keyCode, keyDown: false) else {
            for modifierKeyCode in modifierKeyCodes.reversed() {
                postModifierEvent(keyCode: modifierKeyCode, keyDown: false, eventSource: eventSource)
            }
            return
        }

        keyDown.flags = keystroke.flags
        keyUp.flags = keystroke.flags

        keyDown.post(tap: .cghidEventTap)
        usleep(Self.virtualKeyPressDelayMicroseconds)
        keyUp.post(tap: .cghidEventTap)

        for modifierKeyCode in modifierKeyCodes.reversed() {
            postModifierEvent(keyCode: modifierKeyCode, keyDown: false, eventSource: eventSource)
        }
    }

    /// Type a character using Unicode string (fallback for characters without dedicated virtual keys)
    private func typeCharacterWithUnicode(_ string: String, eventSource: CGEventSource) {
        let unichars = Array(string.utf16)

        guard let keyDown = CGEvent(keyboardEventSource: eventSource, virtualKey: 0, keyDown: true),
              let keyUp = CGEvent(keyboardEventSource: eventSource, virtualKey: 0, keyDown: false) else {
            return
        }

        keyDown.keyboardSetUnicodeString(stringLength: unichars.count, unicodeString: unichars)
        keyUp.keyboardSetUnicodeString(stringLength: unichars.count, unicodeString: unichars)

        keyDown.post(tap: .cghidEventTap)
        usleep(Self.unicodeKeyPressDelayMicroseconds)
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

    private func modifierKeyCodes(for flags: CGEventFlags) -> [CGKeyCode] {
        var keyCodes: [CGKeyCode] = []

        if flags.contains(.maskAlternate) {
            keyCodes.append(0x3A)
        }

        if flags.contains(.maskShift) {
            keyCodes.append(0x38)
        }

        return keyCodes
    }

    private func postModifierEvent(keyCode: CGKeyCode, keyDown: Bool, eventSource: CGEventSource) {
        guard let event = CGEvent(keyboardEventSource: eventSource, virtualKey: keyCode, keyDown: keyDown) else {
            return
        }

        event.post(tap: .cghidEventTap)
    }

    static func hasAccessibilityPermissions() -> Bool {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: false] as CFDictionary
        return AXIsProcessTrustedWithOptions(options)
    }

    static func frontmostApplicationLooksLikeClaudeCode() -> Bool {
        guard let application = NSWorkspace.shared.frontmostApplication else {
            return false
        }

        return looksLikeClaudeCode(
            bundleIdentifier: application.bundleIdentifier,
            localizedName: application.localizedName
        )
    }

    static func looksLikeClaudeCode(bundleIdentifier: String?, localizedName: String?) -> Bool {
        let bundleIdentifier = bundleIdentifier?.lowercased() ?? ""
        let localizedName = localizedName?.lowercased() ?? ""

        return bundleIdentifier.contains("claude")
            || bundleIdentifier.contains("anthropic")
            || localizedName.contains("claude")
    }

    static func requestAccessibilityPermissions() {
        let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!
        NSWorkspace.shared.open(url)
    }
}
