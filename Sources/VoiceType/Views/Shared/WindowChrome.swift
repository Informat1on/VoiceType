import SwiftUI
// WindowChrome.swift — shared badge + chrome primitives.
//
// Tier A Step 3 (2026-04-24): WindowSurface, WindowHeroHeader, SettingsSectionCard,
// SettingsValueRow, InfoChip, and FlowLayout were deleted. AboutView was the last
// caller and has been migrated to native rows per v1-cool-inksteel.html prototype.
// Verified via:
//   grep -rn "WindowSurface|WindowHeroHeader|SettingsSectionCard" Sources/ → 0 callers.
//
// Remaining: StatusBadge (used by AboutView + SettingsView).

struct StatusBadge: View {
    enum Tone {
        case neutral
        case positive
        case warning
        case accent

        var fill: Color {
            switch self {
            case .neutral:  return Palette.textSecondary.opacity(0.14)
            case .positive: return Palette.success.opacity(0.16)
            case .warning:  return Palette.warning.opacity(0.18)
            case .accent:   return Palette.accent.opacity(0.18)
            }
        }

        var foreground: Color {
            switch self {
            case .neutral:  return Palette.textSecondary
            case .positive: return Palette.success
            case .warning:  return Palette.warning
            case .accent:   return Palette.accent
            }
        }
    }

    let text: String
    let tone: Tone

    init(_ text: String, tone: Tone = .neutral) {
        self.text = text
        self.tone = tone
    }

    var body: some View {
        Text(text)
            .font(.caption.weight(.semibold))
            .foregroundStyle(tone.foreground)
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(tone.fill, in: Capsule(style: .continuous))
    }
}
