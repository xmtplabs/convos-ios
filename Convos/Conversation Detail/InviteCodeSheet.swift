import ConvosComposer
import ConvosCore
import SwiftUI

// MARK: - Module overview
//
// The invite code for a conversation, presented as its own sheet with one
// chrome: a title and a close button. Every surface that offers to show a
// code presents this - the chat's invite menu, conversation info, the
// members list, and the Contacts screen's invite rows.
//
// Scanning someone else's code is a separate screen with its own button
// (`JoinConversationView`). The two used to share one view behind a
// Scan/Invite segmented control, presented as an overlay over whatever
// surface opened it, which stacked its chrome on top of the presenter's.

struct InviteCodeSheet: View {
    let conversation: Conversation
    let invite: Invite
    /// Used to watch for a join request the message stream never delivers
    /// while this code is on screen. See `startJoinRequestPolling`.
    let session: any SessionManagerProtocol
    /// Fires when a share completes, so a caller minting a conversation just
    /// to share its code can record that the link is out in the world.
    var onShareCompleted: ((Bool) -> Void)?

    @Environment(\.dismiss) private var dismiss: DismissAction

    var body: some View {
        NavigationStack {
            InviteCodeCard(
                conversation: conversation,
                encodedURLString: invite.inviteURLString,
                isInviteReady: !invite.isEmpty,
                onShareCompleted: { _, completed, _ in
                    onShareCompleted?(completed)
                }
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(.colorBackgroundSurfaceless)
            .navigationTitle("Invite code")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button(role: .close) {
                        dismiss()
                    }
                    .accessibilityIdentifier("invite-code-close-button")
                }
            }
        }
        .onAppear(perform: startJoinRequestPolling)
    }

    /// A code on screen is an invitation someone may be scanning right now,
    /// and their join request arrives as a DM in a brand new conversation -
    /// a topic with no push subscription, so the message stream is the only
    /// live path that carries it. Watch for one the stream misses, rather
    /// than leaving the scanner on "Verifying" until it times out.
    private func startJoinRequestPolling() {
        guard !invite.isEmpty else { return }
        Task {
            await session.messagingService()
                .sessionStateManager
                .startJoinRequestPolling(reason: .inviteShared)
        }
    }
}

#Preview {
    InviteCodeSheet(
        conversation: .mock(),
        invite: .mock(),
        session: ConvosClient.mock().session
    )
}
