import ConvosCore
import SwiftUI
import UIKit

// MARK: - Module overview
//
// `ComposeFlowView` is the Compose entry flow. Single entry point:
//
//   1. MainTabView's Compose button -> `ConversationsViewModel.onStartConvo()`,
//      which presents this sheet only when the user has pickable contacts
//      (with none, it opens the new-conversation view directly and this view
//      is never shown). The picker is hard-wired to `ContactsPickerMode.compose`
//      -- the mode is owned here, not passed by the caller.
//
// The picker's "top three" invite actions (Figma node 4) are owned here too,
// because they all need the claimed conversation + its signed invite that this
// flow already holds in `composeConversationViewModel`:
//   - "Show an invite code" tears the compose flow down and starts a fresh
//     conversation the user lands inside (with the invite QR at the top of the
//     chat), via `ConversationsViewModel.onShowInviteCode()`.
//   - "Send an invite" pops the native share sheet directly with the invite URL.
//   - "Make an agent" tears down this flow and hands off to the shared
//     `ConversationsViewModel.onStartAgent()` entry point.
//
// Mirrors the entry-point-map convention used by `ContactsPickerView` /
// `ContactCardMode` (see CLAUDE.md "View Modes for Multi-Entry-Point Surfaces").

/// Root of the Compose flow, presented as a sheet when the user taps Compose
/// *and has contacts to pick from* (with no contacts, `onStartConvo` skips
/// this entirely and opens the new-conversation view directly).
///
/// A conversation is claimed from the warm cache upfront (by
/// `ConversationsViewModel.onStartConvo`) and handed in as
/// `composeConversationViewModel`.
///
/// Step 1 is the contacts picker in `.compose` mode -- selecting contacts is
/// optional, so its bottom button reads "Skip" until a contact is picked and
/// "Continue" after.
///
/// Step 2 pushes the *same* claimed conversation onto this stack: Skip opens
/// it as-is, Continue first adds the picked contacts. The pushed view shows a
/// close (X) that tears down the whole flow -- there is no back to the picker.
struct ComposeFlowView: View {
    @Bindable var conversationsViewModel: ConversationsViewModel
    let composeConversationViewModel: NewConversationViewModel
    @Bindable var profileSettingsViewModel: ProfileSettingsViewModel
    let contactsRepository: any ContactsRepositoryProtocol
    @State private var pushedConversation: NewConversationViewModel?
    @State private var presentingShareSheet: Bool = false

    var body: some View {
        NavigationStack {
            ContactsPickerView(
                mode: .compose,
                contactsRepository: contactsRepository,
                embedsNavigationStack: false,
                suggestedAgentsService: SuggestedAgentsService.live(),
                onShowInviteCode: handleShowInviteCode,
                onSendInvite: handleSendInvite,
                onMakeAgent: handleMakeAgent,
                onConfirm: handleProceed
            )
            .navigationDestination(item: $pushedConversation) { conversationViewModel in
                NewConversationView(
                    viewModel: conversationViewModel,
                    profileSettingsViewModel: profileSettingsViewModel,
                    embedsNavigationStack: false,
                    onClose: { conversationsViewModel.presentingComposeFlow = false }
                )
            }
        }
        .shareSheet(
            isPresented: $presentingShareSheet,
            items: shareItems
        )
    }

    /// The signed per-conversation invite for the claimed conversation, the
    /// same one the in-convo share flow reads. Empty until the invite is
    /// hydrated.
    private var invite: Invite? {
        let invite = composeConversationViewModel.conversationViewModel?.invite
        guard let invite, !invite.isEmpty else { return nil }
        return invite
    }

    private var shareItems: [Any] {
        guard let invite else { return [] }
        return [invite.inviteURLString]
    }

    /// Tears down the compose flow and starts a fresh conversation the user
    /// lands inside, with the invite QR at the top (the standard message-list
    /// header) -- the same start-and-enter shape as Skip, opted into the
    /// embedded-invite presentation. The compose flow's own claimed
    /// conversation backs Skip / Continue and the share sheet, so it can't
    /// also carry the embedded-invite mode; a dedicated conversation is started
    /// through the shell instead.
    private func handleShowInviteCode() {
        guard invite != nil else { return }
        conversationsViewModel.presentingComposeFlow = false
        conversationsViewModel.onShowInviteCode()
    }

    private func handleSendInvite() {
        guard invite != nil else { return }
        presentingShareSheet = true
    }

    /// Make-an-agent lives behind its own sheet on `MainTabView`, which can't
    /// present from under this sheet -- tear the compose flow down first, then
    /// hand off to the shared entry point.
    private func handleMakeAgent() {
        conversationsViewModel.presentingComposeFlow = false
        conversationsViewModel.onStartAgent()
    }

    /// Skip (empty selection) opens the claimed conversation as-is; Continue
    /// adds the picked humans as members and spawns a fresh instance of each
    /// picked agent template into the conversation. The push happens
    /// immediately either way -- the members / agents land in the open
    /// conversation a moment later. The selection is seeded into the view
    /// model optimistically first, so the conversation indicator shows the
    /// picked end state (names and avatars) instead of "New Convo" while
    /// those calls are in flight; a failed add-members call rolls the
    /// optimistic humans back.
    private func handleProceed(_ memberInboxIds: Set<String>, _ agentTemplateIds: [String]) {
        if let conversationViewModel = composeConversationViewModel.conversationViewModel {
            conversationViewModel.seedOptimisticPickedMembers(
                inboxIds: Array(memberInboxIds),
                agentTemplateIds: agentTemplateIds
            )
            if !memberInboxIds.isEmpty {
                Task {
                    do {
                        try await conversationViewModel.addMembersFromContacts(Array(memberInboxIds))
                    } catch {
                        Log.error("Compose add-members failed, rolling back optimistic members: \(error.localizedDescription)")
                        conversationViewModel.rollbackOptimisticPickedMembers()
                    }
                }
            }
            conversationViewModel.requestAgentJoins(templateIds: agentTemplateIds)
        }
        pushedConversation = composeConversationViewModel
    }
}
