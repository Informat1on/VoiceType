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

    /// Short display label shown in the UI language selector.
    /// Compact to prevent overflow in the Settings → General picker.
    var displayName: String {
        switch self {
        case .auto:          return "Auto"
        case .ru:            return "RU"
        case .en:            return "EN"
        case .bilingualRuEn: return "RU+EN"
        }
    }

    /// Full display label for VoiceOver and accessibility tooltips.
    var longDisplayName: String {
        switch self {
        case .auto:          return "Auto-detect"
        case .ru:            return "Russian"
        case .en:            return "English"
        case .bilingualRuEn: return "Russian + English (bilingual)"
        }
    }
}
