import SwiftWhisper

enum Language: String, Codable, CaseIterable {
    case auto
    case ru
    case en
    case bilingualRuEn = "ru+en"

    var whisperLanguage: WhisperLanguage? {
        switch self {
        case .auto:          return nil
        case .ru:            return .russian
        case .en:            return .english
        case .bilingualRuEn: return .russian  // pin to ru; bilingual prompt is applied in TranscriptionService (step 0c)
        }
    }

    var usesBilingualPrompt: Bool {
        switch self {
        case .auto:          return false
        case .ru:            return false
        case .en:            return false
        case .bilingualRuEn: return true
        }
    }

    /// Human-facing display label (used by SettingsView Picker + AboutView summary).
    var displayName: String {
        switch self {
        case .auto:          return "Auto-detect"
        case .ru:            return "Русский"
        case .en:            return "English"
        case .bilingualRuEn: return "RU + EN (bilingual)"
        }
    }
}
