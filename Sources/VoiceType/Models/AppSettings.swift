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

    var displayName: String {
        switch self {
        case .tiny: return "Tiny (Ultra fast, basic quality)"
        case .base: return "Base (Fast, good quality)"
        case .smallQ5: return "Small Q5 (Balanced speed/quality)"
        case .small: return "Small (Best quality for most use)"
        case .medium: return "Medium (Highest quality, slower)"
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
        }
    }

    var speedRating: String {
        switch self {
        case .tiny: return "⚡⚡⚡⚡⚡"
        case .base: return "⚡⚡⚡⚡"
        case .smallQ5: return "⚡⚡⚡"
        case .small: return "⚡⚡"
        case .medium: return "⚡"
        }
    }

    var qualityRating: String {
        switch self {
        case .tiny: return "Basic"
        case .base: return "Good"
        case .smallQ5: return "Very Good"
        case .small: return "Excellent"
        case .medium: return "Best"
        }
    }

    var recommendedFor: String {
        switch self {
        case .tiny: return "Quick notes, short phrases"
        case .base: return "General use, good speed"
        case .smallQ5: return "Long messages, balanced"
        case .small: return "Professional, high accuracy"
        case .medium: return "Critical accuracy needs"
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

    @Published var preferredLanguage: String {
        didSet { save() }
    }

    @Published var indicatorStyle: IndicatorStyle {
        didSet { save() }
    }

    @Published var textInjectionMode: TextInjectionMode {
        didSet { save() }
    }

    private let defaults = UserDefaults.standard

    private init() {
        self.activationMode = ActivationMode(rawValue: defaults.string(forKey: "activationMode") ?? "") ?? .singlePress
        self.selectedModel = TranscriptionModel(rawValue: defaults.string(forKey: "selectedModel") ?? "") ?? .smallQ5
        self.hotkeyModifiers = defaults.integer(forKey: "hotkeyModifiers") == 0 ? optionKey | cmdKey : defaults.integer(forKey: "hotkeyModifiers")
        self.hotkeyKey = defaults.integer(forKey: "hotkeyKey") == 0 ? 9 : defaults.integer(forKey: "hotkeyKey")
        self.autoEnterAfterInsert = defaults.object(forKey: "autoEnterAfterInsert") as? Bool ?? true
        self.preferredLanguage = defaults.string(forKey: "preferredLanguage") ?? "auto"
        self.indicatorStyle = IndicatorStyle(rawValue: defaults.string(forKey: "indicatorStyle") ?? "") ?? .dot
        self.textInjectionMode = TextInjectionMode(rawValue: defaults.string(forKey: "textInjectionMode") ?? "") ?? .paste
    }

    private func save() {
        defaults.set(activationMode.rawValue, forKey: "activationMode")
        defaults.set(selectedModel.rawValue, forKey: "selectedModel")
        defaults.set(hotkeyModifiers, forKey: "hotkeyModifiers")
        defaults.set(hotkeyKey, forKey: "hotkeyKey")
        defaults.set(autoEnterAfterInsert, forKey: "autoEnterAfterInsert")
        defaults.set(preferredLanguage, forKey: "preferredLanguage")
        defaults.set(indicatorStyle.rawValue, forKey: "indicatorStyle")
        defaults.set(textInjectionMode.rawValue, forKey: "textInjectionMode")
    }
}

// Carbon modifier constants (from Events.h)
let cmdKey: Int = 256       // 1 << 8
let optionKey: Int = 512    // 1 << 9
let controlKey: Int = 1024  // 1 << 10
let shiftKey: Int = 2048    // 1 << 11

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
