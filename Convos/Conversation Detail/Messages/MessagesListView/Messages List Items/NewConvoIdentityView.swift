import SwiftUI

struct NewConvoIdentityView: View {
    var onCopyLink: (() -> Void)?
    var onConvoCode: (() -> Void)?
    var onInviteAgent: (() -> Void)?
    var hasAgent: Bool = false
    var isAgentJoinPending: Bool = false

    private var showInviteMenu: Bool { onCopyLink != nil }

    private var isAgentActionDisabled: Bool { hasAgent || isAgentJoinPending }

    private var agentSubtitle: String {
        if hasAgent { return "Already here" }
        if isAgentJoinPending { return "Joining…" }
        return "Made for this group"
    }

    var body: some View {
        VStack(spacing: DesignConstants.Spacing.step4x) {
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

                    let addFromContactsAction: () -> Void = {
                        // Routed via notification rather than a callback to
                        // avoid plumbing through ~9 layers of Messages / cell
                        // scaffolding. The containing `ConversationView`
                        // observes and presents its existing picker sheet.
                        NotificationCenter.default.post(
                            name: .requestAddFromContactsInCurrentConversation,
                            object: nil
                        )
                    }
                    Button(action: addFromContactsAction) {
                        Text("Add from Contacts")
                        Text("Pick from people you've talked to")
                        Image(systemName: "person.crop.circle.badge.plus")
                    }
                    .accessibilityIdentifier("new-convo-add-from-contacts")

                    let agentAction: () -> Void = { onInviteAgent?() }
                    Button(action: agentAction) {
                        Text("New Agent")
                        Text(agentSubtitle)
                        Image("addAgentIcon")
                            .renderingMode(.template)
                    }
                    .disabled(isAgentActionDisabled)
                } label: {
                    HStack(spacing: DesignConstants.Spacing.step2x) {
                        Image(systemName: "plus")
                        Text("Invite members")
                    }
                    .font(.callout)
                    .foregroundStyle(.colorTextPrimary)
                    .padding(.horizontal, DesignConstants.Spacing.step4x)
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
    }
}

#Preview("Creator") {
    NewConvoIdentityView(
        onCopyLink: {},
        onConvoCode: {},
        onInviteAgent: {}
    )
}

#Preview("Joiner") {
    NewConvoIdentityView()
}
