import SwiftUI
// Tier A Step 2 partial migration (2026-04-24):
// - Safe Spacing token substitutions applied.
// - Inline Color RGB gradient tints removed (out-of-DESIGN.md).
// - cornerRadius 22/26, .thinMaterial, .regularMaterial, Color.white.opacity,
//   font literals remain as design-debt — Step 3 rewrites this file entirely
//   (native rows, no boxed cards, no hero header).

struct WindowSurface<Content: View>: View {
    let title: String
    let subtitle: String
    let symbol: String
    let chips: [String]
    @ViewBuilder let content: Content

    init(
        title: String,
        subtitle: String,
        symbol: String,
        chips: [String] = [],
        @ViewBuilder content: () -> Content
    ) {
        self.title = title
        self.subtitle = subtitle
        self.symbol = symbol
        self.chips = chips
        self.content = content()
    }

    var body: some View {
        ZStack {
            WindowBackground()

            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    WindowHeroHeader(title: title, subtitle: subtitle, symbol: symbol, chips: chips)
                    content
                }
                .padding(Spacing.windowPadding)
                .frame(maxWidth: .infinity, alignment: .topLeading)
            }
            .scrollIndicators(.hidden)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}

private struct WindowBackground: View {
    var body: some View {
        LinearGradient(
            colors: [Color(nsColor: .windowBackgroundColor), Color(nsColor: .underPageBackgroundColor)],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
        .ignoresSafeArea()
    }
}

struct WindowHeroHeader: View {
    let title: String
    let subtitle: String
    let symbol: String
    let chips: [String]

    var body: some View {
        HStack(alignment: .top, spacing: Spacing.lg) {
            VoiceTypeArtwork(size: 86)

            VStack(alignment: .leading, spacing: 10) {
                Label(title, systemImage: symbol)
                    .font(.system(size: 22, weight: .semibold))

                Text(subtitle)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                if !chips.isEmpty {
                    FlowLayout(spacing: Spacing.sm) {
                        ForEach(chips, id: \.self) { chip in
                            InfoChip(text: chip)
                        }
                    }
                }
            }

            Spacer(minLength: 0)
        }
        .padding(20)
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 26, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 26, style: .continuous)
                .strokeBorder(Color.white.opacity(0.08), lineWidth: 1)
        )
    }
}

struct SettingsSectionCard<Content: View>: View {
    let title: String
    let description: String?
    @ViewBuilder let content: Content

    init(
        title: String,
        description: String? = nil,
        @ViewBuilder content: () -> Content
    ) {
        self.title = title
        self.description = description
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.lg) {
            VStack(alignment: .leading, spacing: Spacing.xs) {
                Text(title)
                    .font(.headline)

                if let description {
                    Text(description)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            content
        }
        .padding(20)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .strokeBorder(Color.white.opacity(0.08), lineWidth: 1)
        )
    }
}

struct SettingsValueRow<Value: View>: View {
    let title: String
    @ViewBuilder let value: Value

    init(_ title: String, @ViewBuilder value: () -> Value) {
        self.title = title
        self.value = value()
    }

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: Spacing.lg) {
            Text(title)
                .foregroundStyle(.secondary)

            Spacer(minLength: Spacing.lg)

            value
                .multilineTextAlignment(.trailing)
        }
        .font(.subheadline)
    }
}

struct InfoChip: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.caption.weight(.medium))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(Color.white.opacity(0.08), in: Capsule(style: .continuous))
    }
}

struct StatusBadge: View {
    enum Tone {
        case neutral
        case positive
        case warning
        case accent

        var fill: Color {
            switch self {
            case .neutral: return Color.secondary.opacity(0.14)
            case .positive: return Color.green.opacity(0.16)
            case .warning: return Color.orange.opacity(0.18)
            case .accent: return Color.accentColor.opacity(0.18)
            }
        }

        var foreground: Color {
            switch self {
            case .neutral: return .secondary
            case .positive: return .green
            case .warning: return .orange
            case .accent: return .accentColor
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

private struct FlowLayout<Content: View>: View {
    let spacing: CGFloat
    @ViewBuilder let content: Content

    init(spacing: CGFloat = Spacing.sm, @ViewBuilder content: () -> Content) {
        self.spacing = spacing
        self.content = content()
    }

    var body: some View {
        HStack(spacing: spacing) {
            content
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
