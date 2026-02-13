import SwiftUI

struct FeatureInfoSheet: View {
    let tagline: String?
    let title: String
    let subtitle: String?
    let paragraphs: [FeatureInfoParagraph]
    let primaryButtonTitle: String
    let primaryButtonAction: () -> Void
    let learnMoreURL: URL?

    @Environment(\.openURL) private var openURL: OpenURLAction

    init(
        tagline: String? = nil,
        title: String,
        subtitle: String? = nil,
        paragraphs: [FeatureInfoParagraph] = [],
        primaryButtonTitle: String = "Got it",
        primaryButtonAction: @escaping () -> Void,
        learnMoreURL: URL? = nil
    ) {
        self.tagline = tagline
        self.title = title
        self.subtitle = subtitle
        self.paragraphs = paragraphs
        self.primaryButtonTitle = primaryButtonTitle
        self.primaryButtonAction = primaryButtonAction
        self.learnMoreURL = learnMoreURL
    }

    var body: some View {
        VStack(alignment: .leading, spacing: DesignConstants.Spacing.step4x) {
            if let tagline {
                Text(tagline)
                    .font(.caption)
                    .foregroundStyle(.colorTextSecondary)
            }

            Text(title)
                .font(.system(.largeTitle))
                .fontWeight(.bold)

            if let subtitle {
                Text(subtitle)
                    .font(.body)
                    .foregroundStyle(.colorTextPrimary)
            }

            ForEach(paragraphs) { paragraph in
                Text(paragraph.text)
                    .font(.body)
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
                        Text("Learn more")
                    }
                    .convosButtonStyle(.text)
                    .frame(maxWidth: .infinity)
                }
            }
            .padding(.top, DesignConstants.Spacing.step4x)
        }
        .padding([.leading, .top, .trailing], DesignConstants.Spacing.step10x)
        .padding(.bottom, horizontalSizeClass == .regular ? DesignConstants.Spacing.step10x : 0)
    }

    @Environment(\.horizontalSizeClass) private var horizontalSizeClass: UserInterfaceSizeClass?
}

struct FeatureInfoParagraph: Identifiable {
    let id: String
    let text: String
    let style: Style

    enum Style {
        case primary
        case secondary
    }

    init(_ text: String, style: Style = .secondary) {
        self.id = text
        self.text = text
        self.style = style
    }
}

#Preview("Photos") {
    PhotosInfoSheet()
}

#Preview("Reveal") {
    RevealMediaInfoSheet()
}

#Preview("Explode") {
    ExplodeInfoView()
}

#Preview("Full Convo") {
    FullConvoInfoView(onDismiss: {})
}

#Preview("Locked Convo") {
    LockedConvoInfoView(
        isCurrentUserSuperAdmin: false,
        isLocked: true,
        onLock: {},
        onDismiss: {}
    )
}

#Preview("Maxed Out") {
    MaxedOutInfoView(maxNumberOfConvos: 20)
}

#Preview("Invalid Invite") {
    InfoView(title: "Invalid invite", description: "Looks like this invite isn't active anymore.")
}

#Preview("Pin Limit") {
    PinLimitInfoView()
}

#Preview("Network Issue") {
    ConversationForkedInfoView(onDelete: {})
}
