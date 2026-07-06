#if canImport(UIKit)
import SwiftUI

struct NewConvoIdentityView: View {
    var onCopyLink: (() -> Void)?
    var onConvoCode: (() -> Void)?
    var onInviteAgent: (() -> Void)?
    var isAgentJoinPending: Bool = false

    private var showInviteMenu: Bool { onCopyLink != nil }

    private var isAgentActionDisabled: Bool { isAgentJoinPending }

    private var agentSubtitle: String {
        if isAgentJoinPending { return "Joining…" }
        return "Made for this group"
    }

    var body: some View {
        VStack(spacing: DesignConstants.Spacing.step4x) {
            if showInviteMenu {
                Menu {
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
                        Text("Contacts")
                        Text("People and agents")
                        Image(systemName: "person.crop.circle.badge.plus")
                    }
                    .accessibilityIdentifier("new-convo-add-from-contacts")

                    let agentAction: () -> Void = { onInviteAgent?() }
                    Button(action: agentAction) {
                        Text("New agent")
                        Text(agentSubtitle)
                        Image("addAgentIcon")
                            .renderingMode(.template)
                    }
                    .disabled(isAgentActionDisabled)

                    let convoCodeAction: () -> Void = { onConvoCode?() }
                    Button(action: convoCodeAction) {
                        Text("Invite friends")
                        Text("Link, Airdrop or QR Code")
                        Image(systemName: "square.and.arrow.up")
                    }
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
#endif
