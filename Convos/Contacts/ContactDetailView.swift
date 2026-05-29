import ConvosCore
import SwiftUI
import UIKit

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
//     the agent role label ("Agent", "Verified by ...") for verified
//     agents, otherwise nothing
//   - Chat - hidden for the current user; disabled for verified agents
//     (no DMs yet); calls `contactsWriter.upsertContact(...)` before
//     opening the picker so a synthetic / non-yet-stored contact is
//     promoted to a real one
//   - Get skills / Learn about agents - verified agents only, inline
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
    private let agentTemplateContactsRepository: any AgentTemplateContactsRepositoryProtocol
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

    // Agent-template share / publish state. `resolvedAgentTemplateShareURL`
    // is seeded from `contact.agentTemplatePublishedURL` on appear and
    // updated locally after a successful publish so the row flips from
    // publish-and-share to plain share without waiting for the next
    // contact-profile sync.
    @State private var resolvedAgentTemplateShareURL: URL?
    @State private var isPublishingAgentTemplate: Bool = false
    @State private var isAgentTemplateShareSheetPresented: Bool = false
    @State private var publishAgentTemplateErrorMessage: String?

    init(
        contact: Contact,
        mode: ContactDetailMode = .standalone,
        contactsWriter: any ContactsWriterProtocol,
        contactsRepository: any ContactsRepositoryProtocol,
        agentTemplateContactsRepository: any AgentTemplateContactsRepositoryProtocol
            = MockAgentTemplateContactsRepository(contacts: []),
        session: (any SessionManagerProtocol)? = nil,
        profileSettingsViewModel: ProfileSettingsViewModel = .shared,
        showsCloseButton: Bool = true,
        onRemove: (() -> Void)? = nil
    ) {
        self.contact = contact
        self.mode = mode
        self.contactsWriter = contactsWriter
        self.contactsRepository = contactsRepository
        self.agentTemplateContactsRepository = agentTemplateContactsRepository
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
            .modifier(ContactDetailShareModifier(
                shareURL: resolvedAgentTemplateShareURL,
                isShareSheetPresented: $isAgentTemplateShareSheetPresented,
                publishErrorMessage: $publishAgentTemplateErrorMessage,
                onAppearSeed: seedAgentTemplateShareURLIfNeeded
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

    /// Seeds the in-memory share URL from the freshest source available.
    /// Order:
    ///   1. `contact.agentTemplatePublishedURL` - overlaid from the
    ///      per-conversation member profile by `Contact.resolved(...)`. The
    ///      authoritative source, but lags until the agent broadcasts its
    ///      updated profile and the local membership sync runs.
    ///   2. The cached `DBAgentTemplateContact.publishedURL` row, written
    ///      by any prior publish-on-share flow (this view's own previous
    ///      invocation or the standalone agent-template contact card).
    ///      Lets the share row skip the POST until the member profile
    ///      catches up.
    /// If both miss, the share row stays in publish-and-share mode and the
    /// next tap drives the POST.
    private func seedAgentTemplateShareURLIfNeeded() {
        guard resolvedAgentTemplateShareURL == nil else { return }

        if let urlString = contact.agentTemplatePublishedURL,
           let url = URL(string: urlString) {
            resolvedAgentTemplateShareURL = url
            return
        }

        guard let templateId = contact.agentTemplateId,
              !templateId.isEmpty,
              let session else {
            return
        }
        do {
            let cached = try session.messagingService()
                .agentTemplateContactsRepository()
                .fetchContact(templateId: templateId)
            if let cachedURLString = cached?.publishedURL,
               let url = URL(string: cachedURLString) {
                resolvedAgentTemplateShareURL = url
            }
        } catch {
            Log.error("Failed to read agent-template contact cache for templateId=\(templateId): \(String(describing: error))")
        }
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
                    // A non-template verified agent (Convos / OAuth-verified)
                    // doesn't accept 1:1 DMs today, so its Chat CTA stays
                    // disabled - the agent rows below it remain the way to
                    // interact. A template-backed agent overrides this: Chat
                    // spawns a fresh instance into a new conversation (see
                    // `handleChatWithAgentTemplate`).
                    canSendMessage: session != nil && (!isVerifiedAgent || isAgentTemplate),
                    showChat: !mode.isCurrentUser,
                    showAgentLinks: isVerifiedAgent,
                    showRemove: mode.isScopedToConversation
                        && !mode.isCurrentUser
                        && mode.canRemoveMembers,
                    showBlock: !mode.isCurrentUser,
                    contactDisplayName: contact.resolvedDisplayName,
                    agentTemplateShareURL: agentTemplateShareURL,
                    agentTemplateId: contact.agentTemplateId,
                    isPublishingAgentTemplate: isPublishingAgentTemplate,
                    canPublishAgentTemplate: session != nil,
                    agentInstanceId: contact.agentInstanceId,
                    showsInstanceIdRow: showsInstanceIdRow,
                    agentAttestation: contact.agentAttestation,
                    agentVerification: contact.agentVerification,
                    onSendMessage: isAgentTemplate ? handleChatWithAgentTemplate : handleSendMessage,
                    onPublishAndShareAgentTemplate: handlePublishAndShareAgentTemplate,
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

    /// True when this contact is a template-backed agent - it carries the
    /// `templateId` needed to spawn a fresh instance. Drives the Chat
    /// button's behavior: spawn a new conversation vs. the human DM path.
    private var isAgentTemplate: Bool {
        contact.agentTemplateId != nil
    }

    /// The template share link for a template-backed agent, ready for the
    /// Share row's `ShareLink`. Driven by `resolvedAgentTemplateShareURL`
    /// (seeded from `contact.agentTemplatePublishedURL` on appear) so a
    /// successful publish-on-tap flow flips the row in place. `nil` for
    /// human contacts and for agent templates that have not been published
    /// yet (in that case the share row falls back to a publish-and-share
    /// action driven by `agentTemplateId`).
    private var agentTemplateShareURL: URL? {
        resolvedAgentTemplateShareURL
    }

    /// True on Dev/Local builds. Controls visibility of the instance id
    /// row only - the id itself is always plumbed through.
    private var showsInstanceIdRow: Bool {
        ConfigManager.shared.currentEnvironment.isInternalBuild
    }

    /// Pill rendered below the subtitle. "You" for the current user's
    /// own card, the agent role label for verified agents, otherwise
    /// nothing. The top padding is inside the builder so it doesn't
    /// inflate the gap above the actions row when no badge is showing.
    @ViewBuilder
    private var headerBadge: some View {
        if mode.isCurrentUser {
            RoleLabelPill(label: "You")
                .accessibilityIdentifier("contact-detail-you-badge")
                .padding(.top, DesignConstants.Spacing.step2x)
        } else if let roleLabel = contact.agentVerification?.roleLabel {
            RoleLabelPill(label: roleLabel)
                .accessibilityIdentifier("contact-detail-role-label-\(contact.inboxId)")
                .padding(.top, DesignConstants.Spacing.step2x)
        }
    }

    // MARK: - Picker sheet

    @ViewBuilder
    private var pickerSheet: some View {
        ContactsPickerView(
            mode: .newConversation,
            contactsRepository: contactsRepository,
            agentTemplateContactsRepository: agentTemplateContactsRepository,
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
    private func handlePickerConfirm(_ selection: Set<ContactsPickerViewModel.Selection>) {
        guard !selection.isEmpty, let session else { return }
        let inboxIds: [String] = selection.compactMap(\.inboxId)
        let templateIds: [String] = selection.compactMap(\.templateId)
        presentingNewConvo = NewConversationViewModel(
            session: session,
            mode: .newConversationWithMembers(
                initialMemberInboxIds: inboxIds,
                initialAgentTemplateIds: templateIds
            )
        )
    }

    /// Chat action for a template-backed agent: spawn a fresh instance of
    /// the template into a new conversation. Presented locally via
    /// `presentingNewConvo`, the same sheet anchor `handlePickerConfirm`
    /// uses; the `.newConversationWithTemplate` mode creates the
    /// conversation and joins the agent once it reaches `.ready`.
    private func handleChatWithAgentTemplate() {
        guard let session, let templateId = contact.agentTemplateId else { return }
        presentingNewConvo = NewConversationViewModel(
            session: session,
            mode: .newConversationWithTemplate(templateId: templateId)
        )
    }

    /// Tap handler for the publish-and-share row that fires when the
    /// template-backed agent does not yet carry a `publishedUrl`. Calls
    /// PATCH /api/v2/agent-templates/:id to flip the status to
    /// `published`, then presents the system share sheet with the returned
    /// URL. The URL is also persisted via the messaging service's
    /// agent-template writer when one is reachable so a subsequent visit
    /// (or the standalone agent-template contact card) gets the cached
    /// `ContactDetailShareRow` path. Persistence failures are logged but
    /// non-fatal - the in-memory `resolvedAgentTemplateShareURL` still
    /// drives the share sheet.
    private func handlePublishAndShareAgentTemplate() {
        guard !isPublishingAgentTemplate,
              let session,
              let templateId = contact.agentTemplateId else {
            return
        }
        isPublishingAgentTemplate = true
        Task { @MainActor in
            defer { isPublishingAgentTemplate = false }
            do {
                let template = try await session.publishAgentTemplate(id: templateId)
                guard let urlString = template.publishedUrl,
                      let url = URL(string: urlString) else {
                    Log.error("publishAgentTemplate returned no publishedUrl for templateId=\(templateId), status=\(template.status), urlString=\(template.publishedUrl ?? "<nil>")")
                    publishAgentTemplateErrorMessage = "Couldn't share right now, try again."
                    return
                }
                await persistAgentTemplatePublishedURL(urlString, templateId: templateId, session: session)
                resolvedAgentTemplateShareURL = url
                isAgentTemplateShareSheetPresented = true
            } catch {
                Log.error("publishAgentTemplate failed for templateId=\(templateId): \(String(describing: error))")
                publishAgentTemplateErrorMessage = "Couldn't share right now, try again."
            }
        }
    }

    /// Caches the freshly-published `publishedUrl` onto the local
    /// `DBAgentTemplateContact` row so the next visit to this template
    /// (here or in the standalone agent-template card) seeds the share
    /// row without re-POSTing.
    ///
    /// Two safety properties this method has to preserve:
    ///
    /// 1. Do not nil out other profile fields. `Contact` doesn't carry the
    ///    template's `emoji` or `descriptionText`, and a timestamped
    ///    `AgentTemplateContactSnapshot` wholesale-replaces every field on
    ///    the row (see `AgentTemplateContactsWriter.replacingProfile`). A
    ///    naive `upsert` with `emoji: nil, descriptionText: nil` would
    ///    wipe values written by the standalone card's prior upsert.
    ///    Instead, read the existing row and re-pass every field through
    ///    the snapshot unchanged, only swapping in `publishedURL`.
    ///
    /// 2. Do not auto-add a contact. If the agent has no row in
    ///    `DBAgentTemplateContact`, the user has never opened the
    ///    standalone agent-template card for this template, so we
    ///    shouldn't promote them into the user's agent-template contacts
    ///    as a side effect of tapping Share. Skip the write; the in-memory
    ///    `resolvedAgentTemplateShareURL` covers this view session, and a
    ///    future open of the standalone card (which has the full profile
    ///    to hand) will populate the row properly. Repeat shares from a
    ///    fresh `ContactDetailView` pay the POST cost again, which is
    ///    idempotent and cheap.
    private func persistAgentTemplatePublishedURL(
        _ urlString: String,
        templateId: String,
        session: any SessionManagerProtocol
    ) async {
        let repository = session.messagingService().agentTemplateContactsRepository()
        let existing: AgentTemplateContact?
        do {
            existing = try repository.fetchContact(templateId: templateId)
        } catch {
            Log.error("Failed to read existing agent-template contact for templateId=\(templateId): \(String(describing: error))")
            return
        }
        guard let existing else { return }

        let writer = session.messagingService().agentTemplateContactsWriter()
        let snapshot = AgentTemplateContactSnapshot(
            displayName: existing.displayName,
            emoji: existing.emoji,
            descriptionText: existing.descriptionText,
            publishedURL: urlString,
            avatarURL: existing.avatarURL,
            agentVerification: existing.agentVerification,
            profileUpdatedAt: Date()
        )
        do {
            try await writer.upsert(
                templateId: templateId,
                addedViaConversationId: existing.addedViaConversationId,
                profile: snapshot
            )
        } catch {
            Log.error("Failed to persist publishedURL for templateId=\(templateId): \(String(describing: error))")
        }
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
    /// Non-nil when the template-backed agent has a `publishedUrl`. Drives
    /// the plain `ContactDetailShareRow` (ShareLink) branch of the share
    /// row. `nil` for human contacts, and for templated agents that
    /// haven't been published yet (in which case `agentTemplateId` drives
    /// the publish-and-share branch).
    let agentTemplateShareURL: URL?
    /// Non-nil for template-backed agents. Enables the publish-and-share
    /// branch of the share row when the template doesn't yet carry a
    /// `publishedUrl`. `nil` for human contacts (no share row shown).
    let agentTemplateId: String?
    /// In-flight flag for the publish-and-share row. Drives the disabled
    /// state and the "Sharing..." label while the PATCH is running.
    let isPublishingAgentTemplate: Bool
    /// Disables the publish-and-share row when the parent has no session
    /// (no auth, no api client). Mirrors the existing Chat-row gate.
    let canPublishAgentTemplate: Bool
    /// Always plumbed through when the contact has one. Display gate
    /// is `showsInstanceIdRow`, not nullability of this field.
    let agentInstanceId: String?
    /// True on Dev/Local builds. Hides the row on production.
    let showsInstanceIdRow: Bool
    /// Agent's published attestation signature (`nil` when it joined without
    /// attaching one). Surfaced in the debug-only attestation row.
    let agentAttestation: String?
    /// Last-known agent verification, drives the debug row's valid/invalid
    /// readout alongside the raw attestation value.
    let agentVerification: AgentVerification?
    let onSendMessage: () -> Void
    let onPublishAndShareAgentTemplate: () -> Void
    let onRemove: () -> Void
    let onToggleBlock: () -> Void

    @Environment(\.openURL) private var openURL: OpenURLAction

    var body: some View {
        VStack(spacing: DesignConstants.Spacing.step6x) {
            if showChat {
                chatButton
            }
            agentTemplateShareRow
            if showAgentLinks {
                agentLinkRows
            }
            if showRemove {
                removeRow
            }
            if showBlock {
                blockRow
            }
            if showsInstanceIdRow, let agentInstanceId {
                ContactDetailDebugInstanceIdRow(instanceId: agentInstanceId)
            }
            #if DEBUG
            // Agents only (provisioned, attested, or verified) -- skip human
            // contacts, which carry no attestation. Shows even for unverified
            // agents on purpose: the whole point is to see why one isn't valid.
            if agentInstanceId != nil || agentAttestation != nil || agentVerification?.isVerified == true {
                ContactDetailDebugAttestationRow(
                    attestation: agentAttestation,
                    verification: agentVerification
                )
            }
            #endif
        }
        .padding(.horizontal, DesignConstants.Spacing.step4x)
    }

    /// Renders the agent-template share row in one of three shapes:
    ///   - If the template already has a `publishedUrl`, a SwiftUI
    ///     `ShareLink` (`ContactDetailShareRow`) wired straight to the URL.
    ///   - If the agent is template-backed but has no published URL yet, a
    ///     publish-and-share `ContactDetailActionRow` that drives the
    ///     PATCH-then-share flow in the parent. Shows "Sharing..." while
    ///     the PATCH is in flight.
    ///   - Otherwise (human contact, or templated agent with no session
    ///     access) renders nothing.
    @ViewBuilder
    private var agentTemplateShareRow: some View {
        if let url = agentTemplateShareURL {
            ContactDetailShareRow(
                url: url,
                contactDisplayName: contactDisplayName
            )
        } else if let agentTemplateId, !agentTemplateId.isEmpty {
            // Two-state share button. Label stays "Share" to match the
            // published-state row's affordance; the footer carries the
            // differentiator and hints at the publish step (which needs
            // network), so a user on a flaky connection sees the cause if
            // it fails.
            let publishLabel: String = isPublishingAgentTemplate ? "Sharing..." : "Share"
            let publishFooter: String = "Publish to share a link adding \(contactDisplayName) to a convo"
            ContactDetailActionRow(
                label: publishLabel,
                footer: publishFooter,
                color: .colorTextPrimary,
                isDisabled: isPublishingAgentTemplate || !canPublishAgentTemplate,
                accessibilityLabel: "Publish and share \(contactDisplayName)",
                accessibilityIdentifier: "contact-detail-publish-share",
                action: onPublishAndShareAgentTemplate
            )
        }
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
            label: "Learn about agents",
            footer: "Capabilities, privacy and security",
            color: .colorTextPrimary,
            isDisabled: false,
            accessibilityLabel: "Learn about agents",
            accessibilityIdentifier: "contact-detail-learn-about-agents",
            action: { openURL(AgentLinks.learnAboutAgentsURL) }
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
struct ContactDetailActionRow: View {
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

// MARK: - Share row (template-backed agents)

/// Share row for a template-backed agent. Mirrors `ContactDetailActionRow`'s
/// capsule-plus-footer shape, but wraps a SwiftUI `ShareLink` (which presents
/// the system share sheet) rather than a plain action button, since the
/// share intent is fully handled by the system. Rendered only when the
/// agent carries a template `publishedUrl`.
struct ContactDetailShareRow: View {
    let url: URL
    let contactDisplayName: String

    var body: some View {
        VStack(alignment: .leading, spacing: DesignConstants.Spacing.stepX) {
            ShareLink(item: url) {
                Text("Share")
                    .font(.body)
                    .foregroundStyle(.colorTextPrimary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.vertical, DesignConstants.Spacing.step4x)
                    .padding(.horizontal, DesignConstants.Spacing.step4x)
                    .background(Capsule().fill(.colorFillMinimal))
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Share \(contactDisplayName)")
            .accessibilityIdentifier("contact-card-share-agent-template")
            Text("Share a link to add \(contactDisplayName) to a convo")
                .font(.caption)
                .foregroundStyle(.colorTextSecondary)
                .padding(.horizontal, DesignConstants.Spacing.step4x)
        }
    }
}

// MARK: - Debug instance id row (internal builds only)

/// Internal-build-only row surfacing the agent runtime's `instanceId`
/// for log correlation. Tap the row to copy the value. Gated by the call
/// site in `ContactDetailView` via `AppEnvironment.isInternalBuild`.
/// Mirrors the surrounding action-row shape (capsule + footer caption)
/// so the dev affordance reads as part of the same row family rather
/// than its own visual oddball.
private struct ContactDetailDebugInstanceIdRow: View {
    let instanceId: String

    @State private var didCopy: Bool = false

    var body: some View {
        let footerText: String = didCopy ? "Copied" : "Tap to copy"
        VStack(alignment: .leading, spacing: DesignConstants.Spacing.stepX) {
            Button(action: copyToClipboard) {
                HStack(spacing: DesignConstants.Spacing.step2x) {
                    Text("Instance ID")
                        .font(.body)
                        .foregroundStyle(.colorTextPrimary)
                    Spacer(minLength: DesignConstants.Spacing.step2x)
                    Text(instanceId)
                        .font(.system(.footnote, design: .monospaced))
                        .foregroundStyle(.colorTextSecondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, DesignConstants.Spacing.step4x)
                .padding(.horizontal, DesignConstants.Spacing.step4x)
                .background(Capsule().fill(.colorFillMinimal))
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Instance ID, \(instanceId)")
            .accessibilityHint("Double tap to copy")
            .accessibilityIdentifier("contact-detail-debug-instance-id")
            Text(footerText)
                .font(.caption)
                .foregroundStyle(.colorTextSecondary)
                .padding(.horizontal, DesignConstants.Spacing.step4x)
        }
    }

    private func copyToClipboard() {
        UIPasteboard.general.string = instanceId
        didCopy = true
        Task {
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            didCopy = false
        }
    }
}

#if DEBUG
// MARK: - Debug attestation row (debug builds only)

/// Debug-build-only row surfacing an agent's published attestation signature
/// and whether it currently verifies, so engineers can diagnose in-app why an
/// agent reads as verified or unverified (e.g. an agent that joined without
/// publishing attestation shows "(none)" + "Not verified"). Sits directly
/// below the instance-id row and mirrors its capsule + footer shape. Tap to
/// copy the raw attestation value.
private struct ContactDetailDebugAttestationRow: View {
    let attestation: String?
    let verification: AgentVerification?

    @State private var didCopy: Bool = false

    private var displayValue: String {
        guard let attestation, !attestation.isEmpty else { return "(none)" }
        return attestation
    }

    private var validityText: String {
        switch verification {
        case .verified(let issuer):
            return "Valid - \(issuer.rawValue)"
        case .unverified, .none:
            return attestation == nil ? "No attestation" : "Invalid (not verified)"
        }
    }

    private var isValid: Bool {
        verification?.isVerified == true
    }

    var body: some View {
        let validityColor: Color = isValid ? .colorTextPrimary : .colorTextSecondary
        let footerText: String = didCopy ? "Copied" : validityText
        VStack(alignment: .leading, spacing: DesignConstants.Spacing.stepX) {
            Button(action: copyToClipboard) {
                HStack(spacing: DesignConstants.Spacing.step2x) {
                    Text("Attestation")
                        .font(.body)
                        .foregroundStyle(.colorTextPrimary)
                    Spacer(minLength: DesignConstants.Spacing.step2x)
                    Image(systemName: isValid ? "checkmark.seal.fill" : "xmark.seal")
                        .foregroundStyle(validityColor)
                    Text(displayValue)
                        .font(.system(.footnote, design: .monospaced))
                        .foregroundStyle(.colorTextSecondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, DesignConstants.Spacing.step4x)
                .padding(.horizontal, DesignConstants.Spacing.step4x)
                .background(Capsule().fill(.colorFillMinimal))
            }
            .buttonStyle(.plain)
            .disabled(attestation == nil)
            .accessibilityLabel("Attestation, \(validityText)")
            .accessibilityHint("Double tap to copy")
            .accessibilityIdentifier("contact-detail-debug-attestation")
            Text(footerText)
                .font(.caption)
                .foregroundStyle(.colorTextSecondary)
                .padding(.horizontal, DesignConstants.Spacing.step4x)
        }
    }

    private func copyToClipboard() {
        guard let attestation else { return }
        UIPasteboard.general.string = attestation
        didCopy = true
        Task {
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            didCopy = false
        }
    }
}
#endif

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

/// Modifier wrapping the agent-template share concerns: the activity-sheet
/// presenter (driven by `shareURL` + `isShareSheetPresented`) and the
/// "Couldn't share" alert. Split out from `ContactDetailModalsModifier` so
/// the share concerns don't leak into the generic Block / Picker /
/// SendMessage modifier shape.
private struct ContactDetailShareModifier: ViewModifier {
    let shareURL: URL?
    @Binding var isShareSheetPresented: Bool
    @Binding var publishErrorMessage: String?
    let onAppearSeed: () -> Void

    func body(content: Content) -> some View {
        let isErrorPresented: Binding<Bool> = Binding(
            get: { publishErrorMessage != nil },
            set: { newValue in
                if !newValue { publishErrorMessage = nil }
            }
        )
        content
            .background(shareSheetBackground)
            .alert("Couldn't share", isPresented: isErrorPresented) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(publishErrorMessage ?? "")
            }
            .onAppear(perform: onAppearSeed)
    }

    @ViewBuilder
    private var shareSheetBackground: some View {
        if let shareURL {
            ShareSheetPresenter(
                activityItems: [shareURL],
                isPresented: $isShareSheetPresented
            )
        }
    }
}

/// Thin UIActivityViewController wrapper for presenting the system share
/// sheet imperatively after the publish-and-share PATCH returns. Mirrors
/// the same-named struct in `ConversationShareView.swift` and
/// `AgentTemplateContactCardView.swift`; kept file-local here so this view
/// doesn't depend on either of those.
private struct ShareSheetPresenter: UIViewControllerRepresentable {
    let activityItems: [Any]
    @Binding var isPresented: Bool

    func makeUIViewController(context: Context) -> UIViewController {
        UIViewController()
    }

    func updateUIViewController(_ uiViewController: UIViewController, context: Context) {
        guard isPresented, uiViewController.presentedViewController == nil else { return }
        let activityVC = UIActivityViewController(
            activityItems: activityItems,
            applicationActivities: nil
        )

        if let popover = activityVC.popoverPresentationController {
            popover.sourceView = uiViewController.view
            popover.sourceRect = CGRect(
                x: uiViewController.view.bounds.midX,
                y: uiViewController.view.bounds.maxY,
                width: 0,
                height: 0
            )
            popover.permittedArrowDirections = .up
        }

        activityVC.completionWithItemsHandler = { _, _, _, _ in
            isPresented = false
        }

        uiViewController.present(activityVC, animated: true)
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
        agentVerification: AgentVerification?,
        agentTemplateId: String? = nil,
        agentTemplatePublishedURL: String? = nil,
        profileEmoji: String? = nil,
        agentInstanceId: String? = nil
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
            agentVerification: agentVerification,
            agentTemplateId: agentTemplateId,
            agentTemplatePublishedURL: agentTemplatePublishedURL,
            profileEmoji: profileEmoji,
            agentInstanceId: agentInstanceId
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
    ///
    /// The agent-template `templateId`, `publishedUrl`, and `instanceId`
    /// live only in the per-conversation member profile metadata
    /// (`DBContact` has no template column), so they are overlaid here
    /// onto whichever contact is returned. Without the `templateId`
    /// overlay `isAgentTemplate` is always false.
    public static func resolved(
        member: ConversationMember,
        in conversationId: String,
        contactsRepository: any ContactsRepositoryProtocol
    ) -> Contact {
        let templateId: String? = member.profile.agentTemplateId
        let templatePublishedURL: String? = member.profile.agentTemplatePublishedURL
        let emoji: String? = member.profile.profileEmoji
        let instanceId: String? = member.profile.agentInstanceId
        let attestation: String? = member.profile.agentAttestation
        if let stored = try? contactsRepository.fetchContact(inboxId: member.profile.inboxId) {
            return stored
                .with(agentTemplateId: templateId)
                .with(agentTemplatePublishedURL: templatePublishedURL)
                .with(profileEmoji: emoji)
                .with(agentInstanceId: instanceId)
                .with(agentVerification: member.agentVerification)
                .with(agentAttestation: attestation)
        }
        return .synthetic(
            inboxId: member.profile.inboxId,
            displayName: member.profile.displayName,
            avatarURL: member.profile.avatar,
            avatarSalt: member.profile.avatarSalt,
            avatarNonce: member.profile.avatarNonce,
            avatarKey: member.profile.avatarKey,
            addedViaConversationId: conversationId,
            agentVerification: member.agentVerification,
            agentTemplateId: templateId,
            agentTemplatePublishedURL: templatePublishedURL,
            profileEmoji: emoji,
            agentInstanceId: instanceId
        )
        .with(agentAttestation: attestation)
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
                displayName: "Convos Agent",
                agentVerification: .verified(.convos)
            ),
            contactsWriter: MockContactsWriter(),
            contactsRepository: MockContactsRepository()
        )
    }
}

#Preview("Agent template") {
    NavigationStack {
        ContactDetailView(
            contact: .mock(
                displayName: "Tifoso",
                agentVerification: .verified(.convos),
                agentTemplatePublishedURL: "https://agents-dev.convos.org/tifoso.pnw1o"
            ),
            contactsWriter: MockContactsWriter(),
            contactsRepository: MockContactsRepository()
        )
    }
}

#Preview("Agent template with instance id (dev)") {
    NavigationStack {
        ContactDetailView(
            contact: .mock(
                displayName: "Tifoso",
                agentVerification: .verified(.convos),
                agentTemplatePublishedURL: "https://agents-dev.convos.org/tifoso.pnw1o",
                agentInstanceId: "inst_01HZQX0K7AYB5R8N3W2J6FQGCD"
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
