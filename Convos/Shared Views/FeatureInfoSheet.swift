import SwiftUI

struct FeatureInfoSheet: View {
    let tagline: String?
    let title: String
    let subtitle: String?
    let paragraphs: [FeatureInfoParagraph]
    let primaryButtonTitle: String
    let primaryButtonAction: () -> Void
    let learnMoreTitle: String
    let learnMoreURL: URL?
    let showDragIndicator: Bool

    @Environment(\.openURL) private var openURL: OpenURLAction

    init(
        tagline: String? = nil,
        title: String,
        subtitle: String? = nil,
        paragraphs: [FeatureInfoParagraph] = [],
        primaryButtonTitle: String = "Got it",
        primaryButtonAction: @escaping () -> Void,
        learnMoreTitle: String = "Learn more",
        learnMoreURL: URL? = nil,
        showDragIndicator: Bool = false
    ) {
        self.tagline = tagline
        self.title = title
        self.subtitle = subtitle
        self.paragraphs = paragraphs
        self.primaryButtonTitle = primaryButtonTitle
        self.primaryButtonAction = primaryButtonAction
        self.learnMoreTitle = learnMoreTitle
        self.learnMoreURL = learnMoreURL
        self.showDragIndicator = showDragIndicator
    }

    var body: some View {
        VStack(alignment: .leading, spacing: DesignConstants.Spacing.step4x) {
            if let tagline {
                Text(tagline)
                    .font(.caption)
                    .foregroundStyle(.colorTextSecondary)
            }

            TightLineHeightText(text: title, fontSize: 40, lineHeight: 40)

            if let subtitle {
                Text(subtitle)
                    .font(.body)
                    .foregroundStyle(.colorTextPrimary)
            }

            ForEach(paragraphs) { paragraph in
                Text(paragraph.text)
                    .font(paragraph.size.font)
                    .foregroundStyle(paragraph.style == .primary ? .colorTextPrimary : .colorTextSecondary)
            }

            VStack(spacing: DesignConstants.Spacing.step2x) {
                let action = { primaryButtonAction() }
                Button(action: action) {
                    Text(primaryButtonTitle)
                }
                .convosButtonStyle(.rounded(fullWidth: true))

                if let learnMoreURL {
                    let learnMoreAction = { openURL(learnMoreURL) }
                    Button(action: learnMoreAction) {
                        Text(learnMoreTitle)
                    }
                    .convosButtonStyle(.text)
                    .frame(maxWidth: .infinity)
                }
            }
            .padding(.top, DesignConstants.Spacing.step4x)
        }
        .padding([.leading, .trailing], DesignConstants.Spacing.step10x)
        .padding(.top, DesignConstants.Spacing.step8x)
        .padding(.bottom, horizontalSizeClass == .regular ? DesignConstants.Spacing.step10x : DesignConstants.Spacing.step6x)
        .sheetDragIndicator(showDragIndicator ? .visible : .hidden)
    }

    @Environment(\.horizontalSizeClass) private var horizontalSizeClass: UserInterfaceSizeClass?
}

// UIViewRepresentable approach for precise line height control.
// SwiftUI's .lineSpacing() clamps to 0 (can't reduce below default),
// .leading(.tight) on Font had no visible effect at 40pt,
// and Text(AttributedString(...)) ignores NSParagraphStyle.
// UILabel with min/maxLineHeight is the only reliable way to
// achieve 100% line height (40pt for a 40pt font).
private class SelfSizingLabel: UILabel {
    override func layoutSubviews() {
        super.layoutSubviews()
        preferredMaxLayoutWidth = bounds.width
    }
}

private struct TightLineHeightText: UIViewRepresentable {
    let text: String
    let fontSize: CGFloat
    let lineHeight: CGFloat

    func makeUIView(context: Context) -> SelfSizingLabel {
        let label = SelfSizingLabel()
        label.numberOfLines = 0
        label.lineBreakMode = .byWordWrapping
        label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        label.setContentCompressionResistancePriority(.required, for: .vertical)
        label.setContentHuggingPriority(.required, for: .vertical)
        configureLabel(label)
        return label
    }

    func updateUIView(_ label: SelfSizingLabel, context: Context) {
        configureLabel(label)
    }

    private func configureLabel(_ label: UILabel) {
        let font: UIFont = .systemFont(ofSize: fontSize, weight: .bold)
        let paragraphStyle = NSMutableParagraphStyle()
        paragraphStyle.minimumLineHeight = lineHeight
        paragraphStyle.maximumLineHeight = lineHeight
        label.attributedText = NSAttributedString(
            string: text,
            attributes: [
                .font: font,
                .paragraphStyle: paragraphStyle,
                .baselineOffset: (lineHeight - font.lineHeight) / 2,
                .kern: -1.0,
            ]
        )
    }
}

struct FeatureInfoParagraph: Identifiable {
    let id: String
    let text: String
    let style: Style
    let size: Size

    enum Style {
        case primary
        case secondary
    }

    enum Size {
        case body
        case subheadline
        case small

        var font: Font {
            switch self {
            case .body: .body
            case .subheadline: .subheadline
            case .small: .caption
            }
        }
    }

    init(_ text: String, style: Style = .secondary, size: Size = .body) {
        self.id = text
        self.text = text
        self.style = style
        self.size = size
    }
}

#Preview("Photos") {
    @Previewable @State var isPresented: Bool = true
    VStack { Button { isPresented.toggle() } label: { Text("Show") } }
        .selfSizingSheet(isPresented: $isPresented) { PhotosInfoSheet().padding(.top, 20) }
}

#Preview("Reveal") {
    @Previewable @State var isPresented: Bool = true
    VStack { Button { isPresented.toggle() } label: { Text("Show") } }
        .selfSizingSheet(isPresented: $isPresented) { RevealMediaInfoSheet().padding(.top, 20) }
}

#Preview("Explode") {
    @Previewable @State var isPresented: Bool = true
    VStack { Button { isPresented.toggle() } label: { Text("Show") } }
        .selfSizingSheet(isPresented: $isPresented) { ExplodeInfoView().padding(.top, 20) }
}

#Preview("Full Convo") {
    @Previewable @State var isPresented: Bool = true
    VStack { Button { isPresented.toggle() } label: { Text("Show") } }
        .selfSizingSheet(isPresented: $isPresented) { FullConvoInfoView(onDismiss: { isPresented = false }).padding(.top, 20) }
}

#Preview("Locked Convo") {
    @Previewable @State var isPresented: Bool = true
    VStack { Button { isPresented.toggle() } label: { Text("Show") } }
        .selfSizingSheet(isPresented: $isPresented) {
            LockedConvoInfoView(isCurrentUserSuperAdmin: false, isLocked: true, onLock: {}, onDismiss: { isPresented = false }).padding(.top, 20)
        }
}

#Preview("Maxed Out") {
    @Previewable @State var isPresented: Bool = true
    VStack { Button { isPresented.toggle() } label: { Text("Show") } }
        .selfSizingSheet(isPresented: $isPresented) { MaxedOutInfoView(maxNumberOfConvos: 20).padding(.top, 20) }
}

#Preview("Invalid Invite") {
    @Previewable @State var isPresented: Bool = true
    VStack { Button { isPresented.toggle() } label: { Text("Show") } }
        .selfSizingSheet(isPresented: $isPresented) { InfoView(title: "Invalid invite", description: "Looks like this invite isn't active anymore.").padding(.top, 20) }
}

#Preview("Pin Limit") {
    @Previewable @State var isPresented: Bool = true
    VStack { Button { isPresented.toggle() } label: { Text("Show") } }
        .selfSizingSheet(isPresented: $isPresented) { PinLimitInfoView() }
}

#Preview("Network Issue") {
    @Previewable @State var isPresented: Bool = true
    VStack { Button { isPresented.toggle() } label: { Text("Show") } }
        .selfSizingSheet(isPresented: $isPresented) { ConversationForkedInfoView(onDelete: {}).padding(.top, 20) }
}
