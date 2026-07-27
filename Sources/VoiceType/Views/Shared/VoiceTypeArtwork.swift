import SwiftUI

struct VoiceTypeArtwork: View {
    var size: CGFloat = 92

    private let barHeights: [CGFloat] = [0.26, 0.5, 0.82, 0.62, 0.4]

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: size * 0.28, style: .continuous)
                .fill(
                    LinearGradient(
                        colors: [Palette.Artwork.gradientTop, Palette.Artwork.gradientBottom],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )

            RoundedRectangle(cornerRadius: size * 0.28, style: .continuous)
                .strokeBorder(Color.white.opacity(0.12), lineWidth: 1)

            Circle()
                .fill(
                    RadialGradient(
                        colors: [Palette.Artwork.glowInner, Palette.Artwork.glowOuter],
                        center: .center,
                        startRadius: 4,
                        endRadius: size * 0.34
                    )
                )
                .frame(width: size * 0.3, height: size * 0.3)
                .blur(radius: size * 0.02)
                .offset(x: -size * 0.2, y: -size * 0.1)

            HStack(alignment: .bottom, spacing: size * 0.05) {
                ForEach(Array(barHeights.enumerated()), id: \.offset) { _, height in
                    Capsule(style: .continuous)
                        .fill(
                            LinearGradient(
                                colors: [Color.white.opacity(0.92), Palette.Artwork.barGradientBottom],
                                startPoint: .top,
                                endPoint: .bottom
                            )
                        )
                        .frame(width: size * 0.08, height: size * height)
                }
            }
            .offset(x: size * 0.13, y: size * 0.14)

            Image(systemName: "mic.fill")
                .font(.system(size: size * 0.19, weight: .semibold))
                .foregroundStyle(Color.white.opacity(0.94))
                .offset(x: -size * 0.2, y: -size * 0.12)
        }
        .frame(width: size, height: size)
        .shadow(color: Color.black.opacity(0.22), radius: size * 0.18, y: size * 0.08)
    }
}
