import SwiftUI

struct DesignSystemCatalogView: View {
    @State private var sampleToggle: Bool = true

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: DesignConstants.Spacing.step10x) {
                catalogHeader
                CatalogColorSection()
                CatalogTypographySection()
                catalogComponents
            }
            .frame(maxWidth: DesignConstants.Layout.readableContentWidth, alignment: .leading)
            .padding(.horizontal, DesignConstants.Layout.screenHorizontalInset)
            .padding(.vertical, DesignConstants.Spacing.step10x)
        }
        .convosSurface(.screen)
    }

    private var catalogHeader: some View {
        VStack(alignment: .leading, spacing: DesignConstants.Spacing.step2x) {
            Text("Convos")
                .convosTextStyle(.display)
            Text("Design system")
                .convosTextStyle(.title)
            Text("A living catalog of the visual language already used throughout the app.")
                .convosTextStyle(.supporting)
        }
    }

    private var catalogComponents: some View {
        CatalogSection(title: "Components") {
            VStack(alignment: .leading, spacing: DesignConstants.Spacing.step6x) {
                HStack(spacing: DesignConstants.Spacing.step2x) {
                    ConvosBadge(label: "Agent")
                    ConvosBadge(label: "New", tone: .accent)
                    ConvosBadge(label: "Pending", tone: .warning)
                    ConvosBadge(label: "Blocked", tone: .danger)
                }

                HStack(spacing: DesignConstants.Spacing.step2x) {
                    ConvosIconTile(systemName: "qrcode")
                    ConvosIconTile(systemName: "eye")
                    ConvosIconTile(systemName: "lock")
                }

                VStack(spacing: DesignConstants.Spacing.step2x) {
                    Button("Primary") {}
                        .convosButtonStyle(.rounded(fullWidth: true))
                    Button("Secondary") {}
                        .convosButtonStyle(.outline(fullWidth: true))
                    Button("Text action") {}
                        .convosButtonStyle(.text)
                }

                ConvosSettingsRow(
                    iconSystemName: "eye",
                    title: "Read receipts",
                    subtitle: "Let others know when you have read their messages"
                ) {
                    Toggle("", isOn: $sampleToggle)
                        .labelsHidden()
                }

                ConvosEmptyStateCard(
                    message: "Nothing here yet",
                    actionTitle: "Start a convo"
                ) {}
            }
        }
    }
}

private struct CatalogColorSection: View {
    private let colors: [CatalogColor] = [
        CatalogColor(name: "Background", color: .colorBackgroundSurfaceless),
        CatalogColor(name: "Raised", color: .colorBackgroundRaised),
        CatalogColor(name: "Raised secondary", color: .colorBackgroundRaisedSecondary),
        CatalogColor(name: "Primary text", color: .colorTextPrimary),
        CatalogColor(name: "Secondary text", color: .colorTextSecondary),
        CatalogColor(name: "Primary fill", color: .colorFillPrimary),
        CatalogColor(name: "Minimal fill", color: .colorFillMinimal),
        CatalogColor(name: "Warning", color: .colorWarning),
        CatalogColor(name: "Caution", color: .colorCaution),
    ]

    var body: some View {
        CatalogSection(title: "Semantic colors") {
            LazyVGrid(
                columns: [GridItem(.adaptive(minimum: 140.0), spacing: DesignConstants.Spacing.step3x)],
                spacing: DesignConstants.Spacing.step3x
            ) {
                ForEach(colors) { color in
                    VStack(alignment: .leading, spacing: DesignConstants.Spacing.step2x) {
                        RoundedRectangle(cornerRadius: DesignConstants.CornerRadius.regular)
                            .fill(color.color)
                            .frame(height: 72.0)
                            .overlay {
                                RoundedRectangle(cornerRadius: DesignConstants.CornerRadius.regular)
                                    .stroke(.colorBorderSubtle, lineWidth: DesignConstants.Layout.hairline)
                            }
                        Text(color.name)
                            .convosTextStyle(.label)
                    }
                }
            }
        }
    }
}

private struct CatalogTypographySection: View {
    var body: some View {
        CatalogSection(title: "Typography") {
            VStack(alignment: .leading, spacing: DesignConstants.Spacing.step4x) {
                typographySample("Private by design", style: .display, role: "Display")
                typographySample("A conversation worth keeping", style: .title, role: "Title")
                typographySample("Section heading", style: .headline, role: "Headline")
                typographySample("Messages, settings, and primary content", style: .body, role: "Body")
                typographySample("Secondary body copy", style: .bodySecondary, role: "Body secondary")
                typographySample("Compact empty-state guidance", style: .callout, role: "Callout")
                typographySample("Supporting context and metadata", style: .supporting, role: "Supporting")
                typographySample("Small explanatory copy", style: .detail, role: "Detail")
                typographySample("CONTROL LABEL", style: .label, role: "Label")
                typographySample("Timestamp and quiet detail", style: .caption, role: "Caption")
            }
        }
    }

    private func typographySample(
        _ text: String,
        style: ConvosTextStyle,
        role: String
    ) -> some View {
        VStack(alignment: .leading, spacing: DesignConstants.Spacing.stepHalf) {
            Text(role)
                .convosTextStyle(.caption)
            Text(text)
                .convosTextStyle(style)
        }
    }
}

private struct CatalogSection<Content: View>: View {
    let title: String
    private let content: Content

    init(
        title: String,
        @ViewBuilder content: () -> Content
    ) {
        self.title = title
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: DesignConstants.Spacing.step4x) {
            Text(title)
                .convosTextStyle(.headline)
            content
        }
    }
}

private struct CatalogColor: Identifiable {
    let id: String
    let name: String
    let color: Color

    init(name: String, color: Color) {
        self.id = name
        self.name = name
        self.color = color
    }
}

#Preview("Light") {
    DesignSystemCatalogView()
        .preferredColorScheme(.light)
}

#Preview("Dark") {
    DesignSystemCatalogView()
        .preferredColorScheme(.dark)
}
