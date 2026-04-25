import Foundation

enum ActivationMode: String, Codable, CaseIterable {
    case singlePress = "single"
    case hold = "hold"

    var displayName: String {
        switch self {
        case .singlePress: return "Single Press"
        case .hold: return "Hold to Record"
        }
    }
}

enum IndicatorStyle: String, Codable, CaseIterable {
    case dot = "dot"
    case waveform = "waveform"

    var displayName: String {
        switch self {
        case .dot: return "Pulsing Dot"
        case .waveform: return "Waveform Bars"
        }
    }
}

enum TextInjectionMode: String, Codable, CaseIterable {
    case paste = "paste"
    case type = "type"

    var displayName: String {
        switch self {
        case .paste: return "Paste (Instant)"
        case .type: return "Type (Simulated)"
        }
    }
}

enum TranscriptionModel: String, Codable, CaseIterable {
    case tiny = "tiny"
    case base = "base"
    case smallQ5 = "small-q5_1"
    case small = "small"
    case medium = "medium"
    case largeV3Turbo = "large-v3-turbo"

    var displayName: String {
        switch self {
        case .tiny: return "Tiny (Ultra fast, basic quality)"
        case .base: return "Base (Fast, good quality)"
        case .smallQ5: return "Small Q5 (Balanced speed/quality)"
        case .small: return "Small (Best quality for most use)"
        case .medium: return "Medium (Highest quality, slower)"
        case .largeV3Turbo: return "Large v3 Turbo (Highest quality, fast)"
        }
    }

    var fileName: String {
        "ggml-\(rawValue).bin"
    }

    var downloadURL: String {
        "https://huggingface.co/ggerganov/whisper.cpp/resolve/main/\(fileName)"
    }

    var coreMLFileName: String {
        "ggml-\(rawValue)-encoder.mlmodelc"
    }

    var coreMLDownloadURL: String {
        "https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-\(rawValue)-encoder.mlmodelc.zip"
    }

    var coreMLZipFileName: String {
        "ggml-\(rawValue)-encoder.mlmodelc.zip"
    }
    
    var hasCoreMLSupport: Bool {
        switch self {
        case .smallQ5: return false
        default: return true
        }
    }
    
    var coreMLExplanation: String? {
        switch self {
        case .smallQ5: return "Q5 quantized models don't support CoreML (CPU only)"
        default: return nil
        }
    }

    var estimatedSize: String {
        switch self {
        case .tiny: return "~78 MB"
        case .base: return "~142 MB"
        case .smallQ5: return "~190 MB"
        case .small: return "~466 MB"
        case .medium: return "~1.5 GB"
        case .largeV3Turbo: return "~810 MB"
        }
    }

    var speedRating: String {
        switch self {
        case .tiny: return "⚡⚡⚡⚡⚡"
        case .base: return "⚡⚡⚡⚡"
        case .smallQ5: return "⚡⚡⚡"
        case .small: return "⚡⚡"
        case .medium: return "⚡"
        case .largeV3Turbo: return "⚡⚡⚡⚡"
        }
    }

    var qualityRating: String {
        switch self {
        case .tiny: return "Basic"
        case .base: return "Good"
        case .smallQ5: return "Very Good"
        case .small: return "Excellent"
        case .medium: return "Best"
        case .largeV3Turbo: return "Best"
        }
    }

    var recommendedFor: String {
        switch self {
        case .tiny: return "Quick notes, short phrases"
        case .base: return "General use, good speed"
        case .smallQ5: return "Long messages, balanced"
        case .small: return "Professional, high accuracy"
        case .medium: return "Critical accuracy needs"
        case .largeV3Turbo: return "Best quality with fast turnaround"
        }
    }
}

final class AppSettings: ObservableObject {
    static let shared = AppSettings()

    @Published var activationMode: ActivationMode {
        didSet { save() }
    }

    @Published var selectedModel: TranscriptionModel {
        didSet { save() }
    }

    @Published var hotkeyModifiers: Int {
        didSet { save() }
    }

    @Published var hotkeyKey: Int {
        didSet { save() }
    }

    @Published var autoEnterAfterInsert: Bool {
        didSet { save() }
    }

    @Published var language: Language {
        didSet { save() }
    }

    @Published var customVocabulary: String {
        didSet { save() }
    }

    @Published var indicatorStyle: IndicatorStyle {
        didSet { save() }
    }

    @Published var textInjectionMode: TextInjectionMode {
        didSet { save() }
    }

    @Published var trimWhitespaceAfterInsert: Bool {
        didSet { save() }
    }

    private let defaults = UserDefaults.standard

    private init() {
        self.activationMode = ActivationMode(rawValue: defaults.string(forKey: "activationMode") ?? "") ?? .singlePress
        self.selectedModel = TranscriptionModel(rawValue: defaults.string(forKey: "selectedModel") ?? "") ?? .smallQ5
        let storedModifiers = defaults.integer(forKey: "hotkeyModifiers")
        if storedModifiers == 0 {
            // Factory default per spec audit: Option + Space. This supersedes the
            // pre-fix physical default (Cmd+Shift+V) for users who never customized
            // their hotkey. Intentional breaking change — factory-default users will
            // need to learn the new shortcut or customize back. Customized hotkeys
            // are preserved through the `else` branch via migrateLegacyControlBit.
            self.hotkeyModifiers = optionKey
        } else {
            self.hotkeyModifiers = migrateLegacyControlBit(storedModifiers)
        }
        self.hotkeyKey = defaults.integer(forKey: "hotkeyKey") == 0 ? 49 : defaults.integer(forKey: "hotkeyKey")
        self.autoEnterAfterInsert = defaults.object(forKey: "autoEnterAfterInsert") as? Bool ?? true

        // Language migration: try new key first, then fall back to legacy "preferredLanguage"
        if let newRaw = defaults.string(forKey: "language"),
           let resolved = Language(rawValue: newRaw) {
            self.language = resolved
        } else if let legacyRaw = defaults.string(forKey: "preferredLanguage") {
            switch legacyRaw {
            case "auto": self.language = .auto
            case "ru":   self.language = .ru
            case "en":   self.language = .en
            default:
                print("[AppSettings] Unknown legacy preferredLanguage=\(legacyRaw), defaulting to .bilingualRuEn")
                self.language = .bilingualRuEn
            }
            defaults.removeObject(forKey: "preferredLanguage")
        } else {
            self.language = .bilingualRuEn
        }

        self.customVocabulary = defaults.string(forKey: "customVocabulary") ?? ""

        self.indicatorStyle = IndicatorStyle(rawValue: defaults.string(forKey: "indicatorStyle") ?? "") ?? .dot
        self.textInjectionMode = TextInjectionMode(rawValue: defaults.string(forKey: "textInjectionMode") ?? "") ?? .paste
        self.trimWhitespaceAfterInsert = defaults.object(forKey: "trimWhitespaceAfterInsert") as? Bool ?? true

        // Persist migrated Control bit back to UserDefaults so subsequent launches
        // skip the remap. Only writes when migration actually changed the value.
        if storedModifiers != 0 && storedModifiers != self.hotkeyModifiers {
            defaults.set(self.hotkeyModifiers, forKey: "hotkeyModifiers")
        }
    }

    private func save() {
        defaults.set(activationMode.rawValue, forKey: "activationMode")
        defaults.set(selectedModel.rawValue, forKey: "selectedModel")
        defaults.set(hotkeyModifiers, forKey: "hotkeyModifiers")
        defaults.set(hotkeyKey, forKey: "hotkeyKey")
        defaults.set(autoEnterAfterInsert, forKey: "autoEnterAfterInsert")
        defaults.set(language.rawValue, forKey: "language")
        defaults.set(customVocabulary, forKey: "customVocabulary")
        defaults.set(indicatorStyle.rawValue, forKey: "indicatorStyle")
        defaults.set(textInjectionMode.rawValue, forKey: "textInjectionMode")
        defaults.set(trimWhitespaceAfterInsert, forKey: "trimWhitespaceAfterInsert")
    }
}

// Carbon modifier constants per HIToolbox/Events.h
// cmdKey     = 0x0100 = 256  (1 << 8)
// shiftKey   = 0x0200 = 512  (1 << 9)
// alphaLock  = 0x0400 = 1024 (1 << 10) — not used for hotkeys
// optionKey  = 0x0800 = 2048 (1 << 11)
// controlKey = 0x1000 = 4096 (1 << 12)
let cmdKey: Int     = 256   // 1 << 8
let shiftKey: Int   = 512   // 1 << 9
let optionKey: Int  = 2048  // 1 << 11
let controlKey: Int = 4096  // 1 << 12

/// The `alphaLock` bit (1024, 1 << 10) was mistakenly used as `controlKey` in
/// pre-fix builds. Any UserDefaults value containing this bit represents a
/// Control-based hotkey that was stored with the wrong constant.
internal let legacyAlphaLockBit: Int = 1024

/// Remap legacy Carbon modifier bits for shortcuts that contained the
/// pre-fix `controlKey = 1024` (actually Carbon's alphaLock). These
/// shortcuts never fired under the old constants, so the user never
/// learned a physical combo — we honor their original recorded intent.
///
/// For values WITHOUT bit 1024: no migration. Carbon has been listening
/// on the stored bit value; users have physical muscle memory for that.
/// Migrating would break their working shortcut.
///
/// For values WITH bit 1024: strip bit 1024, swap bits 512 ↔ 2048, add
/// bit 4096. Rationale: pre-fix recorder stored Option as 512 and Shift
/// as 2048, but new constants have 512 = Shift and 2048 = Option. To
/// preserve original physical intent, companion bits must swap.
internal func migrateLegacyControlBit(_ modifiers: Int) -> Int {
    guard modifiers & legacyAlphaLockBit != 0 else { return modifiers }
    var remapped = modifiers & ~legacyAlphaLockBit
    // Swap bits 512 and 2048 to reflect the Option/Shift name-vs-bit inversion.
    let had512 = (remapped & 512) != 0
    let had2048 = (remapped & 2048) != 0
    remapped &= ~(512 | 2048)
    if had512 { remapped |= 2048 }
    if had2048 { remapped |= 512 }
    return remapped | controlKey
}

func modifiersToString(_ modifiers: Int) -> String {
    var result = ""
    if modifiers & controlKey != 0 { result += "⌃" }
    if modifiers & optionKey != 0 { result += "⌥" }
    if modifiers & shiftKey != 0 { result += "⇧" }
    if modifiers & cmdKey != 0 { result += "⌘" }
    return result
}

func keyCodeToString(_ keyCode: Int) -> String {
    let mapping: [Int: String] = [
        0: "A", 1: "S", 2: "D", 3: "F", 4: "H", 5: "G", 6: "Z", 7: "X", 8: "C", 9: "V",
        11: "B", 12: "Q", 13: "W", 14: "E", 15: "R", 16: "Y", 17: "T", 18: "1", 19: "2",
        20: "3", 21: "4", 22: "6", 23: "5", 24: "=", 25: "9", 26: "7", 27: "-", 28: "8",
        29: "0", 31: "O", 32: "U", 33: "[", 34: "I", 35: "P", 37: "L", 38: "J", 39: "'",
        40: "K", 41: ";", 42: "\\", 43: ",", 44: "/", 45: "N", 46: "M", 47: ".", 49: "Space",
        36: "↵", 51: "⌫", 48: "⇥", 53: "Esc"
    ]
    return mapping[keyCode] ?? "Key(\(keyCode))"
}
