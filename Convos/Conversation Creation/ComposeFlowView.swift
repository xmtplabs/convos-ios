import ConvosCore
import SwiftUI

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

    var body: some View {
        NavigationStack {
            ContactsPickerView(
                mode: .compose,
                contactsRepository: contactsRepository,
                embedsNavigationStack: false,
                suggestedAgentsService: SuggestedAgentsService.live(),
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
    }

    /// Skip (empty selection) opens the claimed conversation as-is; Continue
    /// adds the picked humans as members and spawns a fresh instance of each
    /// picked agent template into the conversation. The push happens
    /// immediately either way -- the members / agents land in the open
    /// conversation a moment later.
    private func handleProceed(_ memberInboxIds: Set<String>, _ agentTemplateIds: [String]) {
        if let conversationViewModel = composeConversationViewModel.conversationViewModel {
            if !memberInboxIds.isEmpty {
                Task {
                    try? await conversationViewModel.addMembersFromContacts(Array(memberInboxIds))
                }
            }
            conversationViewModel.requestAgentJoins(templateIds: agentTemplateIds)
        }
        pushedConversation = composeConversationViewModel
    }
}
