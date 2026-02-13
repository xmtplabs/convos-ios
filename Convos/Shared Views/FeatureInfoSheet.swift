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
        .padding(.bottom, horizontalSizeClass == .regular ? DesignConstants.Spacing.step10x : DesignConstants.Spacing.step6x)
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
