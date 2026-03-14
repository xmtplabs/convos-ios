import SwiftUI

struct NewConvoIdentityView: View {
    var onCopyLink: (() -> Void)?
    var onConvoCode: (() -> Void)?
    var onInviteAssistant: (() -> Void)?
    var hasAssistant: Bool = false
    var isAssistantJoinPending: Bool = false
    var isAssistantEnabled: Bool = false

    @State private var presentingInfoSheet: Bool = false

    private var showInviteMenu: Bool { onCopyLink != nil }

    private var isAssistantActionDisabled: Bool { hasAssistant || isAssistantJoinPending }

    private var assistantSubtitle: String {
        if hasAssistant { return "Already here" }
        if isAssistantJoinPending { return "Joining…" }
        return "Helps the group do things"
    }

    var body: some View {
        VStack(spacing: DesignConstants.Spacing.step4x) {
            let infoAction = { presentingInfoSheet = true }
            Button(action: infoAction) {
                HStack(spacing: DesignConstants.Spacing.stepX) {
                    Image(systemName: "infinity.circle.fill")
                        .foregroundStyle(.colorTextTertiary)
                    Text("New convo, new everything")
                        .foregroundStyle(.colorTextSecondary)
                }
                .font(.footnote)
            }

            if showInviteMenu {
                Menu {
                    let copyLinkAction: () -> Void = { onCopyLink?() }
                    Button(action: copyLinkAction) {
                        Text("Invite link")
                        Text("Copy to clipboard")
                        Image(systemName: "link")
                    }

                    let convoCodeAction: () -> Void = { onConvoCode?() }
                    Button(action: convoCodeAction) {
                        Text("Convo code")
                        Text("Show, share or AirDrop it")
                        Image(systemName: "qrcode")
                    }

                    if isAssistantEnabled {
                        let assistantAction: () -> Void = { onInviteAssistant?() }
                        Button(action: assistantAction) {
                            Text("Instant assistant")
                            Text(assistantSubtitle)
                            Image(systemName: "a.circle")
                        }
                        .disabled(isAssistantActionDisabled)
                    }
                } label: {
                    HStack(spacing: DesignConstants.Spacing.step2x) {
                        Image(systemName: "plus.circle.fill")
                        Text("Invite members")
                    }
                    .font(.subheadline)
                    .foregroundStyle(.colorTextPrimary)
                    .padding(.horizontal, DesignConstants.Spacing.step3x)
                    .padding(.vertical, DesignConstants.Spacing.step3HalfX)
                    .background(
                        Capsule()
                            .fill(.colorFillMinimal)
                    )
                }
                .accessibilityIdentifier("invite-members-button")
            }
        }
        .padding(.top, DesignConstants.Spacing.step2x)
        .selfSizingSheet(isPresented: $presentingInfoSheet) {
            NewConvoIdentityInfoSheet()
        }
    }
}

struct NewConvoIdentityInfoSheet: View {
    @Environment(\.dismiss) var dismiss: DismissAction

    var body: some View {
        FeatureInfoSheet(
            tagline: "Private chat for the AI era",
            title: "Every convo is a new world",
            subtitle: "And you're a new you, too.",
            paragraphs: [
                .init("You have Infinite Identities, so you control how you show up, every time.", style: .primary),
                .init("No info is shared between convos, so there's nothing to leak, link or spam.", size: .subheadline),
            ],
            primaryButtonTitle: "Awesome",
            primaryButtonAction: { dismiss() },
            learnMoreTitle: "About infinite identity",
            learnMoreURL: URL(string: "https://learn.convos.org/infinite-identity"),
            showDragIndicator: true
        )
    }
}

#Preview("Creator") {
    NewConvoIdentityView(
        onCopyLink: {},
        onConvoCode: {},
        onInviteAssistant: {},
        isAssistantEnabled: true
    )
}

#Preview("Joiner") {
    NewConvoIdentityView()
}

#Preview("Info Sheet") {
    @Previewable @State var isPresented: Bool = true
    VStack {
        let action = { isPresented.toggle() }
        Button(action: action) { Text("Show") }
    }
    .selfSizingSheet(isPresented: $isPresented) {
        NewConvoIdentityInfoSheet()
    }
}
