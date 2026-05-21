import ConvosCore
import SwiftUI

// MARK: - Module overview
//
// `ContactDetailView` is the single canonical "look at this person" surface
// in the app. It is invoked from two entry points, parameterized by
// `ContactDetailMode`:
//
//   1. Contacts list (`ContactsView`) -> `mode: .standalone`. Default.
//   2. Member-avatar tap inside a chat (`ConversationView` presents
//      `presentingProfileForMember`) -> `mode: .scopedToConversation(...)`.
//
// One row framework for everyone: header / subtitle / optional pill / a
// stack of secondary rows that all share `ContactDetailActionRow`. Human,
// verified-agent, and the current user's own card differ only in *which*
// rows render, in this fixed order:
//
//   - Close (X) button - always, top-leading overlay
//   - Header (avatar + name) - always
//   - Subtitle - "Invited X ago by Y" in scoped mode when the member has a
//     `joinedAt`; otherwise "Added X ago" from `contact.addedAt`
//   - Pill below the subtitle - "You" for the current user's own card,
//     the agent role label ("Assistant", "Verified by ...") for verified
//     agents, otherwise nothing
//   - Chat - hidden for the current user; disabled for verified agents
//     (no DMs yet); calls `contactsWriter.upsertContact(...)` before
//     opening the picker so a synthetic / non-yet-stored contact is
//     promoted to a real one
//   - Get skills / Learn about assistants - verified agents only, inline
//     in the action stack after Chat
//   - Remove - scoped mode only, when the viewer is an admin
//     (`canRemoveMembers`) and the tapped member is not the current user
//   - Block / Unblock - hidden for the current user; both modes otherwise
//
// Mirrors `ContactsPickerMode`'s "one component, two entry points" pattern.

/// Unified contact detail view. See module-overview comment above for
/// entry-point mapping and section visibility rules.
struct ContactDetailView: View {
    let contact: Contact
    let mode: ContactDetailMode
    /// True when the view should render its own X close button in the
    /// nav-bar's cancellation slot. Sheet entry points (where there is no
    /// system back button) keep this on; NavigationLink push entry points
    /// (where the system already renders a chevron back button) pass false
    /// so the user doesn't see two redundant dismiss controls.
    let showsCloseButton: Bool
    private let contactsWriter: any ContactsWriterProtocol
    private let contactsRepository: any ContactsRepositoryProtocol
    private let session: (any SessionManagerProtocol)?
    private let profileSettingsViewModel: ProfileSettingsViewModel
    private let onRemove: (() -> Void)?

    @Environment(\.dismiss) private var dismiss: DismissAction
    @State private var isBlocked: Bool
    @State private var isApplyingBlockChange: Bool = false
    @State private var presentingBlockConfirmation: Bool = false
    @State private var presentingPicker: Bool = false
    @State private var presentingSendMessageError: Bool = false
    @State private var sendMessageErrorMessage: String?
    @State private var presentingNewConvo: NewConversationViewModel?

    init(
        contact: Contact,
        mode: ContactDetailMode = .standalone,
        contactsWriter: any ContactsWriterProtocol,
        contactsRepository: any ContactsRepositoryProtocol,
        session: (any SessionManagerProtocol)? = nil,
        profileSettingsViewModel: ProfileSettingsViewModel = .shared,
        showsCloseButton: Bool = true,
        onRemove: (() -> Void)? = nil
    ) {
        self.contact = contact
        self.mode = mode
        self.contactsWriter = contactsWriter
        self.contactsRepository = contactsRepository
        self.session = session
        self.profileSettingsViewModel = profileSettingsViewModel
        self.showsCloseButton = showsCloseButton
        self.onRemove = onRemove
        _isBlocked = State(initialValue: contact.isBlocked)
    }

    var body: some View {
        bodyContent
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(.colorBackgroundRaisedSecondary)
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(.hidden, for: .navigationBar)
            .toolbar { closeToolbarItem }
            .modifier(ContactDetailModalsModifier(
                presentingBlockConfirmation: $presentingBlockConfirmation,
                presentingPicker: $presentingPicker,
                presentingSendMessageError: $presentingSendMessageError,
                sendMessageErrorMessage: sendMessageErrorMessage,
                blockAlertTitle: blockAlertTitle,
                blockAlertMessage: blockAlertMessage,
                blockAlertActions: { blockAlertActions },
                pickerSheet: { pickerSheet }
            ))
            .sheet(item: $presentingNewConvo) { vm in
                NewConversationView(
                    viewModel: vm,
                    profileSettingsViewModel: profileSettingsViewModel
                )
                .background(.colorBackgroundSurfaceless)
            }
            .task(id: contact.inboxId) { await syncBlockedState() }
    }

    @ToolbarContentBuilder
    private var closeToolbarItem: some ToolbarContent {
        if showsCloseButton {
            ToolbarItem(placement: .cancellationAction) {
                let action = { dismiss() }
                Button(role: .cancel, action: action)
                    .accessibilityIdentifier("contact-detail-close")
            }
        }
    }

    @ViewBuilder
    private var bodyContent: some View {
        // ScrollView (not a plain VStack with a Spacer) because verified
        // agents render two extra link rows + a Remove row above Block,
        // and on smaller phones that content can exceed the sheet's
        // height. The previous VStack+Spacer layout pushed long content
        // *up* behind the transparent toolbar - the avatar would visually
        // overlap with the close button. A ScrollView keeps the header
        // pinned below the toolbar and lets the rest scroll.
        ScrollView {
            // Spacing 0 here is load-bearing: `headerBadge` returns an
            // `EmptyView` when there's no pill to show, and a non-zero
            // VStack spacing would still reserve space around that empty
            // view, inflating the gap between subtitle and actions.
            VStack(spacing: 0.0) {
                ContactDetailHeader(contact: contact)
                ContactDetailSubtitle(
                    contact: contact,
                    invitedBy: mode.invitedBy,
                    joinedAt: mode.joinedAt,
                    isBlocked: isBlocked
                )
                .padding(.top, DesignConstants.Spacing.step2x)
                headerBadge
                ContactDetailActions(
                    isBlocked: isBlocked,
                    isApplyingBlockChange: isApplyingBlockChange,
                    // Verified agents (Convos / OAuth-verified) don't accept
                    // 1:1 DMs today, so the Chat CTA would open a conversation
                    // that goes nowhere. Disable until DM support for agents
                    // lands; the agent rows that follow the Chat button
                    // remain the right way to interact.
                    canSendMessage: session != nil && !isVerifiedAgent,
                    showChat: !mode.isCurrentUser,
                    showAgentLinks: isVerifiedAgent,
                    showRemove: mode.isScopedToConversation
                        && !mode.isCurrentUser
                        && mode.canRemoveMembers,
                    showBlock: !mode.isCurrentUser,
                    contactDisplayName: contact.resolvedDisplayName,
                    onSendMessage: handleSendMessage,
                    onRemove: handleRemoveTap,
                    onToggleBlock: handleBlockTap
                )
                .padding(.top, DesignConstants.Spacing.step8x)
                .padding(.bottom, 80.0)
            }
        }
        // ScrollView on short content (human card with just Chat + Block)
        // would otherwise rubber-band on touch even though the content
        // already fits. `.basedOnSize` disables bounce when the content
        // fits the viewport and re-enables it when it doesn't (agent or
        // self card on smaller phones).
        .scrollBounceBehavior(.basedOnSize)
    }

    // MARK: - Derived

    private var isVerifiedAgent: Bool {
        contact.isVerifiedAgent
    }

    /// Pill rendered below the subtitle. "You" for the current user's
    /// own card, the agent role label for verified agents, otherwise
    /// nothing. The top padding is inside the builder so it doesn't
    /// inflate the gap above the actions row when no badge is showing.
    @ViewBuilder
    private var headerBadge: some View {
        if mode.isCurrentUser {
            ContactDetailBadge(
                label: "You",
                accessibilityIdentifier: "contact-detail-you-badge"
            )
            .padding(.top, DesignConstants.Spacing.step2x)
        } else if let roleLabel = contact.agentVerification?.roleLabel {
            ContactDetailBadge(
                label: roleLabel,
                accessibilityIdentifier: "contact-detail-role-label-\(contact.inboxId)"
            )
            .padding(.top, DesignConstants.Spacing.step2x)
        }
    }

    // MARK: - Picker sheet

    @ViewBuilder
    private var pickerSheet: some View {
        ContactsPickerView(
            mode: .newConversation,
            contactsRepository: contactsRepository,
            preselectedInboxIds: [contact.inboxId],
            onConfirm: handlePickerConfirm
        )
    }

    // MARK: - Block alert content

    private var blockAlertTitle: String {
        isBlocked ? "Unblock \(contact.resolvedDisplayName)?" : "Block \(contact.resolvedDisplayName)?"
    }

    private var blockAlertMessage: String {
        if isBlocked {
            return "You'll start receiving new conversation invitations from this contact again."
        }
        return "They won't be able to start new conversations with you. Existing shared groups are unaffected."
    }

    @ViewBuilder
    private var blockAlertActions: some View {
        Button("Cancel", role: .cancel) {}
        if isBlocked {
            Button("Unblock", action: handleUnblockConfirmed)
        } else {
            Button("Block", role: .destructive, action: handleBlockConfirmed)
        }
    }

    // MARK: - Actions

    private func handleSendMessage() {
        Task {
            do {
                // Idempotent. For a contact already in the DB, the writer
                // preserves the original `addedAt` and `addedViaConversationId`
                // and merges only the profile snapshot. For a synthetic contact
                // (passed in from a chat member-tap on a non-contact), this
                // promotes them to a real contact attributed to the source
                // conversation. See PRD, "Send-message on a non-contact" section.
                try await contactsWriter.upsertContact(
                    inboxId: contact.inboxId,
                    addedViaConversationId: contact.addedViaConversationId ?? mode.conversationId,
                    profile: ContactProfileSnapshot(
                        displayName: contact.displayName,
                        avatarURL: contact.avatarURL,
                        avatarSalt: contact.avatarSalt,
                        avatarNonce: contact.avatarNonce,
                        avatarKey: contact.avatarKey,
                        profileUpdatedAt: nil,
                        agentVerification: contact.agentVerification
                    )
                )
            } catch {
                Log.error("Failed to upsert contact \(contact.inboxId): \(error.localizedDescription)")
                await MainActor.run {
                    sendMessageErrorMessage = "We couldn't open the message picker. Please try again."
                    presentingSendMessageError = true
                }
                return
            }
            await MainActor.run {
                routeToChat()
            }
        }
    }

    /// Decides where "Chat" lands the user. If the current user
    /// already has a 1:1 with this contact, the existing conversation
    /// opens in the same sheet anchor we use for the new-convo flow -
    /// otherwise the picker takes over (preselected with this contact)
    /// so the standard new-convo creation path runs. Prevents the
    /// "tap Chat twice, end up with two 1:1s with the same person"
    /// regression.
    private func routeToChat() {
        if let session, let existing = findExistingOneToOne(session: session) {
            presentingNewConvo = NewConversationViewModel(
                session: session,
                mode: .existingConversation(conversationId: existing.id)
            )
        } else {
            presentingPicker = true
        }
    }

    /// Looks for an active 1:1 (current user + this contact, no other
    /// non-self members) in the user's accepted *and* pending
    /// conversations. The repository pushes the predicate into SQL so
    /// we don't hydrate every conversation just to find one match.
    ///
    /// `.unknown` is included alongside `.allowed` so an outstanding
    /// invite from this contact routes "Chat" into that pending
    /// thread instead of letting the user create a duplicate convo
    /// alongside it; the chat's own consent gate handles the accept /
    /// decline flow from there. Locked conversations are intentionally
    /// included - "locked" only freezes invite-code minting; the chat
    /// itself still works, and routing to an existing locked 1:1 is
    /// preferable to spinning up a second one. Drafts, expired,
    /// quarantined, and unused conversations are excluded upstream.
    ///
    /// When this view is opened scoped to a conversation
    /// (`mode.conversationId != nil`) the source conversation is
    /// excluded from the search - if the user is already chatting in
    /// a 1:1 with this contact and taps "Chat", they almost certainly
    /// want a different chat, so falling through to the picker is the
    /// right move. Multiple 1:1s with the same person are allowed; the
    /// SQL ordering picks the most-recently-active alternative.
    private func findExistingOneToOne(session: any SessionManagerProtocol) -> Conversation? {
        try? session
            .conversationsRepository(for: [.allowed, .unknown])
            .findOneToOne(with: contact.inboxId, excluding: mode.conversationId)
    }

    private func handleBlockTap() {
        presentingBlockConfirmation = true
    }

    private func handleBlockConfirmed() {
        applyBlockChange(block: true)
    }

    private func handleUnblockConfirmed() {
        applyBlockChange(block: false)
    }

    private func handleRemoveTap() {
        onRemove?()
    }

    private func applyBlockChange(block: Bool) {
        guard !isApplyingBlockChange else { return }
        isApplyingBlockChange = true
        let inboxId = contact.inboxId
        let snapshot = ContactProfileSnapshot(
            displayName: contact.displayName,
            avatarURL: contact.avatarURL,
            avatarSalt: contact.avatarSalt,
            avatarNonce: contact.avatarNonce,
            avatarKey: contact.avatarKey,
            profileUpdatedAt: nil,
            agentVerification: contact.agentVerification
        )
        let addedViaConversationId = contact.addedViaConversationId ?? mode.conversationId
        Task { @MainActor in
            defer { isApplyingBlockChange = false }
            do {
                if block {
                    // Synthetic contacts (opened from a chat-member-tap on a
                    // non-contact) have no DB row yet. Upsert first so
                    // `block()` has somewhere to write `blockedAt`; idempotent
                    // for real contacts. Mirrors the pattern used by
                    // `handleSendMessage` and `ConversationViewModel.blockAndLeaveConvo`.
                    try await contactsWriter.upsertContact(
                        inboxId: inboxId,
                        addedViaConversationId: addedViaConversationId,
                        profile: snapshot
                    )
                    try await contactsWriter.block(inboxId: inboxId)
                } else {
                    try await contactsWriter.unblock(inboxId: inboxId)
                }
                isBlocked = block
            } catch {
                Log.error("Failed to update blocked state for \(inboxId): \(error.localizedDescription)")
            }
        }
    }

    /// Spins up a `NewConversationViewModel` locally and presents it as a
    /// sheet from this view, so the new conversation appears in place of
    /// the picker while whatever hosts this contact card (App Settings
    /// sheet stack, or the chat) stays alive underneath. Mirrors
    /// `ContactsView.handlePickerConfirm` and the invite-cell-tap pattern
    /// where the new-convo sheet is owned by the same view that hosted
    /// the picker.
    private func handlePickerConfirm(_ inboxIds: Set<String>) {
        guard !inboxIds.isEmpty, let session else { return }
        presentingNewConvo = NewConversationViewModel(
            session: session,
            mode: .newConversationWithMembers(initialMemberInboxIds: Array(inboxIds))
        )
    }

    private func syncBlockedState() async {
        do {
            guard let updated = try contactsRepository.fetchContact(inboxId: contact.inboxId) else {
                return
            }
            isBlocked = updated.isBlocked
        } catch {
            Log.error("Failed to sync blocked state for \(contact.inboxId): \(error.localizedDescription)")
        }
    }
}

// MARK: - Header

private struct ContactDetailHeader: View {
    let contact: Contact

    var body: some View {
        VStack(spacing: DesignConstants.Spacing.step4x) {
            ContactAvatarView(contact: contact)
                .frame(width: 160.0, height: 160.0)

            Text(contact.resolvedDisplayName)
                .font(.largeTitle.weight(.bold))
                .foregroundStyle(.colorTextPrimary)
        }
    }
}

/// Small capsule pill rendered below the subtitle. Used for the
/// verified-agent role label ("Assistant", "Verified by ...") and for
/// the "You" indicator on the current user's own card - same shape so
/// the spacing around the pill mirrors the surrounding label spacing
/// regardless of which one is showing.
private struct ContactDetailBadge: View {
    let label: String
    let accessibilityIdentifier: String

    var body: some View {
        Text(label)
            .font(.footnote)
            .foregroundStyle(.colorTextSecondary)
            .padding(.horizontal, DesignConstants.Spacing.step2x)
            .padding(.vertical, DesignConstants.Spacing.stepX)
            .background(.colorTextSecondary.opacity(0.1), in: .capsule)
            .accessibilityIdentifier(accessibilityIdentifier)
    }
}

// MARK: - Subtitle

/// Renders "Invited X ago by Y" when scoped-mode `joinedAt` is available,
/// otherwise "Added X ago" sourced from `contact.addedAt`. The blocked row
/// is appended underneath when the contact is currently blocked.
private struct ContactDetailSubtitle: View {
    let contact: Contact
    let invitedBy: Profile?
    let joinedAt: Date?
    let isBlocked: Bool

    var body: some View {
        VStack(spacing: DesignConstants.Spacing.stepX) {
            Text(subtitleText)
                .foregroundStyle(.colorTextSecondary)
            if isBlocked {
                blockedRow
            }
        }
        .font(.subheadline)
        .frame(maxWidth: .infinity)
        .padding(.horizontal, DesignConstants.Spacing.step3x)
    }

    private var subtitleText: String {
        if let joinedAt {
            let prefix = "Invited \(relativeString(for: joinedAt))"
            if let inviter = invitedBy?.displayName, !inviter.isEmpty {
                return "\(prefix) by \(inviter)"
            }
            return prefix
        }
        return "Added \(relativeString(for: contact.addedAt))"
    }

    private func relativeString(for date: Date) -> String {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .abbreviated
        return formatter.localizedString(for: date, relativeTo: Date())
    }

    private var blockedRow: some View {
        HStack(spacing: 4.0) {
            Image(systemName: "nosign")
            Text("Blocked")
        }
        .foregroundStyle(.colorCaution)
    }
}

// MARK: - Action stack

/// Renders Chat (always first) plus any combination of the verified-
/// agent links, Remove, and Block - in that order. Chat is the primary
/// CTA (filled dark pill); the rest use the secondary action-row style
/// (capsule label + caption below) so an agent and human card share
/// one row framework and only differ in which rows render.
private struct ContactDetailActions: View {
    let isBlocked: Bool
    let isApplyingBlockChange: Bool
    let canSendMessage: Bool
    let showChat: Bool
    let showAgentLinks: Bool
    let showRemove: Bool
    let showBlock: Bool
    let contactDisplayName: String
    let onSendMessage: () -> Void
    let onRemove: () -> Void
    let onToggleBlock: () -> Void

    @Environment(\.openURL) private var openURL: OpenURLAction

    var body: some View {
        VStack(spacing: DesignConstants.Spacing.step6x) {
            if showChat {
                chatButton
            }
            if showAgentLinks {
                agentLinkRows
            }
            if showRemove {
                removeRow
            }
            if showBlock {
                blockRow
            }
        }
        .padding(.horizontal, DesignConstants.Spacing.step4x)
    }

    @ViewBuilder
    private var agentLinkRows: some View {
        ContactDetailActionRow(
            label: "Get skills",
            footer: "Browse 100+ curated capabilities",
            color: .colorTextPrimary,
            isDisabled: false,
            accessibilityLabel: "Get skills",
            accessibilityIdentifier: "contact-detail-get-skills",
            action: { openURL(AgentLinks.getSkillsURL) }
        )
        ContactDetailActionRow(
            label: "Learn about assistants",
            footer: "Capabilities, privacy and security",
            color: .colorTextPrimary,
            isDisabled: false,
            accessibilityLabel: "Learn about assistants",
            accessibilityIdentifier: "contact-detail-learn-about-assistants",
            action: { openURL(AgentLinks.learnAboutAssistantsURL) }
        )
    }

    private var chatButton: some View {
        let backgroundOpacity: Double = canSendMessage ? 1.0 : 0.4
        return Button(action: onSendMessage) {
            Text("Chat")
                .font(.body.weight(.medium))
                .foregroundStyle(.colorTextPrimaryInverted)
                .frame(maxWidth: .infinity)
                .padding(.vertical, DesignConstants.Spacing.step4x)
                .background(
                    RoundedRectangle(cornerRadius: 32.0)
                        .fill(.colorTextPrimary.opacity(backgroundOpacity))
                )
        }
        .disabled(!canSendMessage)
        .accessibilityLabel("Chat with \(contactDisplayName)")
        .accessibilityIdentifier("contact-detail-chat")
    }

    private var removeRow: some View {
        ContactDetailActionRow(
            label: "Remove",
            footer: "Remove from convo",
            color: .colorTextPrimary,
            isDisabled: false,
            accessibilityLabel: "Remove \(contactDisplayName)",
            accessibilityIdentifier: "remove-member-button",
            action: onRemove
        )
    }

    private var blockRow: some View {
        let label: String = isBlocked ? "Unblock" : "Block"
        let footer: String = isBlocked
            ? "Start receiving convo invites from \(contactDisplayName) again"
            : "So they can't contact you"
        let identifier: String = isBlocked ? "contact-detail-unblock" : "contact-detail-block"
        return ContactDetailActionRow(
            label: label,
            footer: footer,
            color: .colorCaution,
            isDisabled: isApplyingBlockChange,
            accessibilityLabel: "\(label) \(contactDisplayName)",
            accessibilityIdentifier: identifier,
            action: onToggleBlock
        )
    }
}

// MARK: - Shared action row

/// Reusable row for the secondary actions (Remove, Block). The shape -
/// rounded white pill on top with a small grey footer caption below - is
/// the canonical card action style. The label color is the only knob: dark
/// primary for affirmative actions, caution red for destructive.
private struct ContactDetailActionRow: View {
    let label: String
    let footer: String
    let color: Color
    let isDisabled: Bool
    let accessibilityLabel: String
    let accessibilityIdentifier: String
    let action: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: DesignConstants.Spacing.stepX) {
            Button(action: action) {
                Text(label)
                    .font(.body)
                    .foregroundStyle(color)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.vertical, DesignConstants.Spacing.step4x)
                    .padding(.horizontal, DesignConstants.Spacing.step4x)
                    .background(Capsule().fill(.colorFillMinimal))
            }
            .buttonStyle(.plain)
            .disabled(isDisabled)
            .accessibilityLabel(accessibilityLabel)
            .accessibilityIdentifier(accessibilityIdentifier)
            Text(footer)
                .font(.caption)
                .foregroundStyle(.colorTextSecondary)
                .padding(.horizontal, DesignConstants.Spacing.step4x)
        }
    }
}

// MARK: - Modals modifier

private struct ContactDetailModalsModifier<
    BlockActions: View,
    PickerContent: View
>: ViewModifier {
    @Binding var presentingBlockConfirmation: Bool
    @Binding var presentingPicker: Bool
    @Binding var presentingSendMessageError: Bool
    let sendMessageErrorMessage: String?
    let blockAlertTitle: String
    let blockAlertMessage: String
    let blockAlertActions: () -> BlockActions
    let pickerSheet: () -> PickerContent

    func body(content: Content) -> some View {
        content
            .alert(blockAlertTitle, isPresented: $presentingBlockConfirmation) {
                blockAlertActions()
            } message: {
                Text(blockAlertMessage)
            }
            .alert(
                "Couldn't open message picker",
                isPresented: $presentingSendMessageError,
                presenting: sendMessageErrorMessage
            ) { _ in
                Button("OK", role: .cancel) {}
            } message: { message in
                Text(message)
            }
            .sheet(isPresented: $presentingPicker) {
                pickerSheet()
            }
    }
}

// MARK: - Synthetic contact for member taps

extension Contact {
    /// Builds a presentation-only `Contact` from a chat member when the
    /// inbox is not yet a stored contact. The card uses this until the user
    /// taps "Chat", at which point the writer's idempotent upsert promotes
    /// the synthetic to a real contact attributed to the source conversation.
    public static func synthetic(
        inboxId: String,
        displayName: String?,
        avatarURL: String?,
        avatarSalt: Data? = nil,
        avatarNonce: Data? = nil,
        avatarKey: Data? = nil,
        addedViaConversationId: String?,
        agentVerification: AgentVerification?
    ) -> Contact {
        Contact(
            inboxId: inboxId,
            displayName: displayName,
            avatarURL: avatarURL,
            avatarSalt: avatarSalt,
            avatarNonce: avatarNonce,
            avatarKey: avatarKey,
            addedAt: Date(),
            addedViaConversationId: addedViaConversationId,
            isBlocked: false,
            agentVerification: agentVerification
        )
    }

    /// Resolves the contact for `member.profile.inboxId`: returns the
    /// stored `Contact` if the inbox is a known contact, otherwise a
    /// synthetic one built from the member's profile snapshot.
    ///
    /// Used by the chat-side `ContactDetailView` entry points (member-avatar
    /// tap, members list) so the view renders uniformly for contact members
    /// and non-contact members. The synthetic fallback is promoted to a
    /// real contact when the user taps "Chat".
    public static func resolved(
        member: ConversationMember,
        in conversationId: String,
        contactsRepository: any ContactsRepositoryProtocol
    ) -> Contact {
        if let stored = try? contactsRepository.fetchContact(inboxId: member.profile.inboxId) {
            return stored
        }
        return .synthetic(
            inboxId: member.profile.inboxId,
            displayName: member.profile.displayName,
            avatarURL: member.profile.avatar,
            avatarSalt: member.profile.avatarSalt,
            avatarNonce: member.profile.avatarNonce,
            avatarKey: member.profile.avatarKey,
            addedViaConversationId: conversationId,
            agentVerification: member.agentVerification
        )
    }
}

#Preview("Default") {
    NavigationStack {
        ContactDetailView(
            contact: .mock(displayName: "Alice"),
            contactsWriter: MockContactsWriter(),
            contactsRepository: MockContactsRepository()
        )
    }
}

#Preview("Blocked") {
    NavigationStack {
        ContactDetailView(
            contact: .mock(displayName: "Alice", isBlocked: true),
            contactsWriter: MockContactsWriter(),
            contactsRepository: MockContactsRepository()
        )
    }
}

#Preview("Verified agent") {
    NavigationStack {
        ContactDetailView(
            contact: .mock(
                displayName: "Convos Assistant",
                agentVerification: .verified(.convos)
            ),
            contactsWriter: MockContactsWriter(),
            contactsRepository: MockContactsRepository()
        )
    }
}

#Preview("Scoped to conversation, admin") {
    NavigationStack {
        ContactDetailView(
            contact: .mock(displayName: "Andy"),
            mode: .scopedToConversation(
                conversationId: "convo-1",
                canRemoveMembers: true,
                isCurrentUser: false,
                invitedBy: Profile.mock(name: "Shane"),
                joinedAt: Date().addingTimeInterval(-20 * 60)
            ),
            contactsWriter: MockContactsWriter(),
            contactsRepository: MockContactsRepository(),
            onRemove: {}
        )
    }
}
