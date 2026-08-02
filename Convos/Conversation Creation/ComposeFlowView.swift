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
// No conversation is claimed while the picker is merely open -- opening
// Compose and cancelling must leave no trace. Each action mints on intent:
//   - "Show an invite code" tears the compose flow down and starts a fresh
//     conversation the user lands inside (with the invite QR at the top of the
//     chat), via `ConversationsViewModel.onShowInviteCode()`.
//   - "Send an invite" mints a hidden claimed conversation on tap and pops the
//     native share sheet with its invite URL; the share outcome decides the
//     conversation's fate (committed visible on completion, discarded on
//     cancel). Same lifecycle the Contacts tab's top-three uses.
//   - The bottom CTA mints a `.newConversationWithMembers` conversation seeded
//     with the picked contacts / agent templates (or none: the empty-selection
//     "New convo / Invite friends later" button skips inviting entirely) and
//     pushes it onto this stack.
//
// Mirrors the entry-point-map convention used by `ContactsPickerView` /
// `ContactCardMode` (see CLAUDE.md "View Modes for Multi-Entry-Point Surfaces").

/// Root of the Compose flow, presented as a sheet when the user taps Compose
/// *and has contacts to pick from* (with no contacts, `onStartConvo` skips
/// this entirely and opens the new-conversation view directly).
///
/// Step 1 is the contacts picker in `.compose` mode -- selecting contacts is
/// optional. The bottom CTA is always present: with contacts picked it reads
/// "Continue", with none it reads "New convo / Invite friends later" and
/// skips the invite step entirely.
///
/// Step 2 pushes a freshly minted conversation carrying the picked members
/// onto this stack once Continue is tapped. The pushed view shows a close (X)
/// that tears down the whole flow -- there is no back to the picker.
struct ComposeFlowView: View {
    @Bindable var conversationsViewModel: ConversationsViewModel
    @Bindable var profileSettingsViewModel: ProfileSettingsViewModel
    let contactsRepository: any ContactsRepositoryProtocol
    @State private var pushedConversation: NewConversationViewModel?
    /// Claimed warm-cache conversation (mode `.newConversation`, which already
    /// has an invite) minted on demand when the user taps "Send an invite" --
    /// never at picker open, so composing and cancelling can't claim (and then
    /// churn or leak) a conversation. Minted with deferred visibility, so it
    /// stays out of the chats list until the share completes.
    @State private var inviteConversationViewModel: NewConversationViewModel?
    @State private var presentingShareSheet: Bool = false
    /// Invite link captured when the share sheet is presented, so its content
    /// survives `presentShareSheet` detaching the claimed conversation from
    /// `inviteConversationViewModel`.
    @State private var inviteShareURL: String?
    /// Retains the invite conversation across the native "Send an invite" share
    /// sheet so its outcome decides the conversation's fate: a completed share
    /// keeps it (committed visible, marked shared); a cancelled share discards
    /// the still-hidden claimed row so it doesn't linger empty in the chats list.
    @State private var sharedInviteViewModel: NewConversationViewModel?
    /// Set when "Send an invite" was tapped before the on-demand claim's
    /// signed invite hydrated. Shows a spinner on the row and lets the
    /// `invite?.urlSlug` observer pop the share sheet the moment the invite
    /// arrives, so the tap is never a silent no-op. The rows themselves are
    /// always visible ("static menu, dynamic action") -- readiness is handled
    /// at tap time, never by hiding rows.
    @State private var isPreparingInviteShare: Bool = false

    var body: some View {
        NavigationStack {
            ContactsPickerView(
                mode: .compose,
                contactsRepository: contactsRepository,
                embedsNavigationStack: false,
                suggestedAgentsService: SuggestedAgentsService.live(),
                sendInviteShowsProgress: isPreparingInviteShare,
                onShowInviteCode: handleShowInviteCode,
                onSendInvite: handleSendInvite,
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
        .onChange(of: invite?.urlSlug) { _, slug in
            handleInviteSlugChanged(slug)
        }
        .onDisappear(perform: discardUnenteredInviteConversation)
        .shareSheet(
            isPresented: $presentingShareSheet,
            items: shareItems,
            onCompletion: { _, completed, _ in
                handleInviteShareCompleted(completed: completed)
            }
        )
    }

    /// The signed per-conversation invite for the on-demand claimed
    /// conversation, the same one the in-convo share flow reads. Nil until
    /// "Send an invite" mints the claim and its invite hydrates.
    private var invite: Invite? {
        let invite = inviteConversationViewModel?.conversationViewModel?.invite
        guard let invite, !invite.isEmpty else { return nil }
        return invite
    }

    private var shareItems: [Any] {
        guard let inviteShareURL else { return [] }
        return [inviteShareURL]
    }

    /// Mints the claimed conversation on demand, when the user taps
    /// "Send an invite". Same shape as the Contacts tab's on-demand mint.
    private func claimInviteConversationIfNeeded() {
        guard inviteConversationViewModel == nil else { return }
        inviteConversationViewModel = NewConversationViewModel(
            session: conversationsViewModel.session,
            mode: .newConversation,
            showsEmbeddedInvite: true,
            defersInviteVisibilityUntilEntered: true,
            coreActions: conversationsViewModel.coreActions
        )
    }

    /// Discards a pending "Send an invite" claim the user never shared. The
    /// convo was minted with deferred visibility so it never surfaced in the
    /// chats list; this only releases the hidden claimed cache row. Runs when
    /// the compose sheet leaves the hierarchy, and when another intent
    /// (Show-code, Continue) supersedes the pending share.
    private func discardUnenteredInviteConversation() {
        isPreparingInviteShare = false
        inviteConversationViewModel?.cleanUpEmptyEmbeddedInviteIfNeeded()
        inviteConversationViewModel = nil
    }

    /// Tears down the compose flow and starts a fresh conversation the user
    /// lands inside, with the invite QR at the top (the standard message-list
    /// header). Needs no local claim or hydrated invite: the destination convo
    /// mints its own and shows a loading QR until it arrives -- exactly one
    /// conversation is created.
    private func handleShowInviteCode() {
        discardUnenteredInviteConversation()
        conversationsViewModel.presentingComposeFlow = false
        conversationsViewModel.onShowInviteCode()
    }

    /// Mints a hidden claimed conversation on demand and pops the native share
    /// sheet with its invite link. If the invite hasn't hydrated yet, the row
    /// shows a spinner and `handleInviteSlugChanged` presents the share sheet
    /// the moment the signed invite arrives.
    private func handleSendInvite() {
        claimInviteConversationIfNeeded()
        guard invite != nil else {
            isPreparingInviteShare = true
            return
        }
        presentShareSheet()
    }

    /// Continues a pending "Send an invite" once the on-demand claimed
    /// conversation's signed invite hydrates.
    private func handleInviteSlugChanged(_ slug: String?) {
        guard slug != nil, isPreparingInviteShare else { return }
        isPreparingInviteShare = false
        presentShareSheet()
    }

    /// Captures the link and detaches the still-hidden claimed convo into
    /// `sharedInviteViewModel`; `handleInviteShareCompleted` decides its fate
    /// by the share outcome.
    private func presentShareSheet() {
        guard let invite, let sharedViewModel = inviteConversationViewModel else { return }
        inviteShareURL = invite.inviteURLString
        inviteConversationViewModel = nil
        sharedInviteViewModel = sharedViewModel
        presentingShareSheet = true
    }

    /// Resolves the shared invite conversation once the native share sheet
    /// closes. A completed share commits it visible and marks its invite shared
    /// so the empty-convo teardown keeps it; a cancelled share discards the
    /// still-hidden claimed row so it doesn't linger empty in the chats list.
    private func handleInviteShareCompleted(completed: Bool) {
        guard let sharedViewModel = sharedInviteViewModel else { return }
        sharedInviteViewModel = nil
        guard completed else {
            sharedViewModel.cleanUpEmptyEmbeddedInviteIfNeeded()
            return
        }
        sharedViewModel.markInviteShared()
        Task { await sharedViewModel.commitConversationVisibility() }
    }

    /// The bottom CTA mints a fresh conversation seeded with the picked humans
    /// and agent templates (`.newConversationWithMembers`, the same mode the
    /// contacts-list picker confirm uses) and pushes it immediately -- the
    /// members / agents land in the open conversation a moment later, with the
    /// picked identities painted optimistically by the seeded-members
    /// machinery. An empty selection is valid: the "New convo / Invite friends
    /// later" button skips the invite step and lands straight in the
    /// conversation, where the default agent greets.
    private func handleProceed(_ memberInboxIds: Set<String>, _ agentTemplateIds: [String]) {
        discardUnenteredInviteConversation()
        pushedConversation = NewConversationViewModel(
            session: conversationsViewModel.session,
            mode: .newConversationWithMembers(
                initialMemberInboxIds: Array(memberInboxIds),
                initialAgentTemplateIds: agentTemplateIds
            ),
            coreActions: conversationsViewModel.coreActions
        )
    }
}
