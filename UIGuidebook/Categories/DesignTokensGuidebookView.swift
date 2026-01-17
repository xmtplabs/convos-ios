import SwiftUI

struct DesignTokensGuidebookView: View {
    var body: some View {
        ScrollView {
            VStack(spacing: 24) {
                colorsSection
                spacingSection
                cornerRadiusSection
                fontsSection
                imageSizesSection
            }
            .padding()
        }
        .background(Color(.systemGroupedBackground))
    }

    private var colorsSection: some View {
        ComponentShowcase(
            "Colors",
            description: "Semantic color tokens from Assets.xcassets"
        ) {
            VStack(spacing: 16) {
                Text("Text Colors")
                    .font(.caption.bold())
                    .frame(maxWidth: .infinity, alignment: .leading)

                LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 12) {
                    ColorSwatch(name: "colorTextPrimary", color: .colorTextPrimary)
                    ColorSwatch(name: "colorTextSecondary", color: .colorTextSecondary)
                    ColorSwatch(name: "colorTextTertiary", color: .colorTextTertiary)
                    ColorSwatch(name: "colorTextPrimaryInverted", color: .colorTextPrimaryInverted, darkBg: true)
                    ColorSwatch(name: "colorTextDarkBg", color: .colorTextDarkBg, darkBg: true)
                    ColorSwatch(name: "colorTextInactive", color: .colorTextInactive)
                }

                Divider()

                Text("Background Colors")
                    .font(.caption.bold())
                    .frame(maxWidth: .infinity, alignment: .leading)

                LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 12) {
                    ColorSwatch(name: "colorBackgroundPrimary", color: .colorBackgroundPrimary)
                    ColorSwatch(name: "colorBackgroundSubtle", color: .colorBackgroundSubtle)
                    ColorSwatch(name: "colorBackgroundRaised", color: .colorBackgroundRaised)
                    ColorSwatch(name: "colorBackgroundInverted", color: .colorBackgroundInverted, darkBg: true)
                    ColorSwatch(name: "backgroundSurface", color: .backgroundSurface)
                }

                Divider()

                Text("Fill Colors")
                    .font(.caption.bold())
                    .frame(maxWidth: .infinity, alignment: .leading)

                LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 12) {
                    ColorSwatch(name: "colorFillPrimary", color: .colorFillPrimary, darkBg: true)
                    ColorSwatch(name: "colorFillSecondary", color: .colorFillSecondary)
                    ColorSwatch(name: "colorFillTertiary", color: .colorFillTertiary)
                    ColorSwatch(name: "colorFillMinimal", color: .colorFillMinimal)
                }

                Divider()

                Text("Border Colors")
                    .font(.caption.bold())
                    .frame(maxWidth: .infinity, alignment: .leading)

                LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 12) {
                    ColorSwatch(name: "colorBorderSubtle", color: .colorBorderSubtle)
                    ColorSwatch(name: "colorBorderSubtle2", color: .colorBorderSubtle2)
                }

                Divider()

                Text("Accent Colors")
                    .font(.caption.bold())
                    .frame(maxWidth: .infinity, alignment: .leading)

                LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 12) {
                    ColorSwatch(name: "colorOrange", color: .colorOrange)
                    ColorSwatch(name: "colorGreen", color: .colorGreen)
                    ColorSwatch(name: "colorCaution", color: .colorCaution)
                    ColorSwatch(name: "colorLava", color: .colorLava)
                    ColorSwatch(name: "colorPurpleMute", color: .colorPurpleMute)
                    ColorSwatch(name: "colorStandard", color: .colorStandard)
                }

                Divider()

                Text("Special Colors")
                    .font(.caption.bold())
                    .frame(maxWidth: .infinity, alignment: .leading)

                LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 12) {
                    ColorSwatch(name: "colorBubble", color: .colorBubble)
                    ColorSwatch(name: "colorBubbleIncoming", color: .colorBubbleIncoming)
                    ColorSwatch(name: "colorLinkBackground", color: .colorLinkBackground)
                    ColorSwatch(name: "colorDarkAlpha15", color: .colorDarkAlpha15)
                }
            }
        }
    }

    private var spacingSection: some View {
        ComponentShowcase(
            "DesignConstants.Spacing",
            description: "Standard spacing values for consistent layout"
        ) {
            VStack(spacing: 16) {
                SpacingRow(name: "stepHalf", value: DesignConstants.Spacing.stepHalf)
                SpacingRow(name: "stepX", value: DesignConstants.Spacing.stepX)
                SpacingRow(name: "step2x", value: DesignConstants.Spacing.step2x)
                SpacingRow(name: "step3x", value: DesignConstants.Spacing.step3x)
                SpacingRow(name: "step3HalfX", value: DesignConstants.Spacing.step3HalfX)
                SpacingRow(name: "step4x", value: DesignConstants.Spacing.step4x)
                SpacingRow(name: "step5x", value: DesignConstants.Spacing.step5x)
                SpacingRow(name: "step6x", value: DesignConstants.Spacing.step6x)
                SpacingRow(name: "step8x", value: DesignConstants.Spacing.step8x)
                SpacingRow(name: "step9x", value: DesignConstants.Spacing.step9x)
                SpacingRow(name: "step10x", value: DesignConstants.Spacing.step10x)
                SpacingRow(name: "step11x", value: DesignConstants.Spacing.step11x)
                SpacingRow(name: "step12x", value: DesignConstants.Spacing.step12x)
                SpacingRow(name: "step16x", value: DesignConstants.Spacing.step16x)

                Divider()

                SpacingRow(name: "small", value: DesignConstants.Spacing.small)
                SpacingRow(name: "medium", value: DesignConstants.Spacing.medium)
            }
        }
    }

    private var cornerRadiusSection: some View {
        ComponentShowcase(
            "DesignConstants.CornerRadius",
            description: "Standard corner radius values for rounded elements"
        ) {
            VStack(spacing: 16) {
                CornerRadiusRow(name: "small", value: DesignConstants.CornerRadius.small)
                CornerRadiusRow(name: "regular", value: DesignConstants.CornerRadius.regular)
                CornerRadiusRow(name: "medium", value: DesignConstants.CornerRadius.medium)
                CornerRadiusRow(name: "mediumLarge", value: DesignConstants.CornerRadius.mediumLarge)
                CornerRadiusRow(name: "mediumLarger", value: DesignConstants.CornerRadius.mediumLarger)
                CornerRadiusRow(name: "large", value: DesignConstants.CornerRadius.large)
            }
        }
    }

    private var fontsSection: some View {
        ComponentShowcase(
            "DesignConstants.Fonts",
            description: "Standard font definitions"
        ) {
            VStack(spacing: 16) {
                FontRow(name: "standard", font: DesignConstants.Fonts.standard, description: "24pt")
                FontRow(name: "medium", font: DesignConstants.Fonts.medium, description: "16pt")
                FontRow(name: "small", font: DesignConstants.Fonts.small, description: "12pt")
                FontRow(name: "buttonText", font: DesignConstants.Fonts.buttonText, description: "14pt")
            }
        }
    }

    private var imageSizesSection: some View {
        ComponentShowcase(
            "DesignConstants.ImageSizes",
            description: "Standard avatar/image sizes"
        ) {
            HStack(spacing: 24) {
                VStack {
                    Circle()
                        .fill(.colorFillTertiary)
                        .frame(width: DesignConstants.ImageSizes.extraSmallAvatar)
                    Text("extraSmall")
                        .font(.caption2)
                    Text("\(Int(DesignConstants.ImageSizes.extraSmallAvatar))pt")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }

                VStack {
                    Circle()
                        .fill(.colorFillTertiary)
                        .frame(width: DesignConstants.ImageSizes.smallAvatar)
                    Text("small")
                        .font(.caption2)
                    Text("\(Int(DesignConstants.ImageSizes.smallAvatar))pt")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }

                VStack {
                    Circle()
                        .fill(.colorFillTertiary)
                        .frame(width: DesignConstants.ImageSizes.mediumAvatar)
                    Text("medium")
                        .font(.caption2)
                    Text("\(Int(DesignConstants.ImageSizes.mediumAvatar))pt")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }

                VStack {
                    Circle()
                        .fill(.colorFillTertiary)
                        .frame(width: DesignConstants.ImageSizes.largeAvatar)
                    Text("large")
                        .font(.caption2)
                    Text("\(Int(DesignConstants.ImageSizes.largeAvatar))pt")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }
}

private struct ColorSwatch: View {
    let name: String
    let color: Color
    var darkBg: Bool = false

    var body: some View {
        VStack(spacing: 4) {
            RoundedRectangle(cornerRadius: 8)
                .fill(color)
                .frame(height: 44)
                .overlay(
                    RoundedRectangle(cornerRadius: 8)
                        .stroke(.quaternary, lineWidth: 1)
                )
            Text(name)
                .font(.system(size: 9, design: .monospaced))
                .lineLimit(1)
                .foregroundStyle(darkBg ? .secondary : .primary)
        }
    }
}

private struct SpacingRow: View {
    let name: String
    let value: CGFloat

    var body: some View {
        HStack {
            Text(".\(name)")
                .font(.caption.monospaced())
                .frame(width: 100, alignment: .leading)

            Rectangle()
                .fill(.colorFillPrimary)
                .frame(width: value, height: 16)

            Spacer()

            Text("\(Int(value))pt")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }
}

private struct CornerRadiusRow: View {
    let name: String
    let value: CGFloat

    var body: some View {
        HStack {
            Text(".\(name)")
                .font(.caption.monospaced())
                .frame(width: 120, alignment: .leading)

            RoundedRectangle(cornerRadius: value)
                .fill(.colorFillPrimary)
                .frame(width: 60, height: 40)

            Spacer()

            Text("\(Int(value))pt")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }
}

private struct FontRow: View {
    let name: String
    let font: Font
    let description: String

    var body: some View {
        HStack {
            Text(".\(name)")
                .font(.caption.monospaced())
                .frame(width: 100, alignment: .leading)

            Text("Sample Text")
                .font(font)

            Spacer()

            Text(description)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }
}

#Preview {
    NavigationStack {
        DesignTokensGuidebookView()
            .navigationTitle("Design Tokens")
    }
}
