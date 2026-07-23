import ConvosComposer
import ConvosCore
import ConvosMetrics
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
//     the agent role label ("Agent", "Verified by ...") for verified
//     agents, otherwise nothing
//   - "Convos with you" sections - template-backed agents only, listing
//     conversations that already contain the agent; rows push the
//     conversation onto the host navigation stack
//   - New chat - hidden for the current user; disabled for verified agents
//     (no DMs yet); calls `contactsWriter.upsertContact(...)` before
//     opening the picker so a synthetic / non-yet-stored contact is
//     promoted to a real one
//   - Share - template-backed agents with a published link, after New chat
//   - Contact Info - agents with an email address in their profile
//     metadata; the row opens the mail composer, the trailing button
//     copies the address
//   - Remove - scoped mode only, when the viewer is an admin
//     (`canRemoveMembers`) and the tapped member is not the current user
//   - Block / Unblock - hidden for the current user; both modes otherwise
//
// Mirrors `ContactsPickerMode`'s "one component, two entry points" pattern.

/// Unified contact detail view. See module-overview comment above for
/// entry-point mapping and section visibility rules.
struct ContactDetailView: View {
    let contact: Contact
    /// Dev-only variant marker, passed from the live member profile at the
    /// chat-side entry point (`nil` elsewhere). Drives the 🧪 variant card on
    /// the agent profile, mirroring the in-chat ribbon.
    let variantStamp: AgentVariantStamp?
    let mode: ContactDetailMode
    /// True when the view should render its own X close button in the
    /// nav-bar's cancellation slot. Sheet entry points (where there is no
    /// system back button) keep this on; NavigationLink push entry points
    /// (where the system already renders a chevron back button) pass false
    /// so the user doesn't see two redundant dismiss controls.
    let showsCloseButton: Bool
    /// Whether a conversation pushed from the "Convos with you" rows should
    /// inset its indicator below the device's top safe area. Only the
    /// Contacts tab passes true - its push lands full screen, extending
    /// under the status bar. Every sheet-hosted card (member tap in a chat,
    /// members list) keeps the default false: the sheet's top edge already
    /// sits below the status bar, so the device inset would render the
    /// indicator too far down. Not derivable from `showsCloseButton` - the
    /// members list pushes the card (no X) but its stack lives in a sheet.
    let pushedConversationInsetsTopSafeArea: Bool
    private let contactsWriter: any ContactsWriterProtocol
    private let contactsRepository: any ContactsRepositoryProtocol
    private let session: (any SessionManagerProtocol)?
    private let coreActions: any CoreActions
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
    /// Existing conversation pushed onto the host navigation stack when the
    /// user taps a row in the "Convos with you" sections.
    @State private var pushedConversation: NewConversationViewModel?
    @State private var presentingAgentShareSheet: Bool = false
    /// Conversations already containing this agent template, split by who
    /// added the agent. Loaded on appear for template-backed agents; drives
    /// the "Convos with you" / "someone else added them" sections.
    @State private var agentTemplateConversations: AgentTemplateConversations = .empty
    /// Gates the "New chat, new context" confirmation before the "Chat"
    /// button spawns a new conversation with this agent. `agentInfoConfirmed`
    /// distinguishes a "Got it" tap from a drag-to-cancel in the sheet's
    /// `onDismiss`.
    @State private var presentingAgentInfo: Bool = false
    @State private var agentInfoConfirmed: Bool = false
    /// The agent template's description, resolved on appear for template-backed
    /// agents (it isn't stored on the contact). Rendered under the name.
    @State private var agentDescription: String?
    @State private var navState: ContactCardNavigatorImpl = .init()
    @State private var navigator: ContactCardCollector?

    private func ensureNavigator() {
        guard navigator == nil else { return }
        navigator = ContactCardCollector(
            instance: navState,
            delegate: PostHogConfiguration.sharedMetricsDelegate ?? CollectorDelegate()
        )
    }

    init(
        contact: Contact,
        variantStamp: AgentVariantStamp? = nil,
        mode: ContactDetailMode = .standalone,
        contactsWriter: any ContactsWriterProtocol,
        contactsRepository: any ContactsRepositoryProtocol,
        session: (any SessionManagerProtocol)? = nil,
        coreActions: any CoreActions,
        profileSettingsViewModel: ProfileSettingsViewModel = .shared,
        showsCloseButton: Bool = true,
        pushedConversationInsetsTopSafeArea: Bool = false,
        onRemove: (() -> Void)? = nil
    ) {
        self.contact = contact
        self.variantStamp = variantStamp
        self.mode = mode
        self.contactsWriter = contactsWriter
        self.contactsRepository = contactsRepository
        self.session = session
        self.coreActions = coreActions
        self.profileSettingsViewModel = profileSettingsViewModel
        self.showsCloseButton = showsCloseButton
        self.pushedConversationInsetsTopSafeArea = pushedConversationInsetsTopSafeArea
        self.onRemove = onRemove
        _isBlocked = State(initialValue: contact.isBlocked)
        // Suggested-agent contacts carry the description, so it renders
        // immediately; saved agent contacts seed nil and resolve it on appear.
        _agentDescription = State(initialValue: contact.agentDescription)
    }

    var body: some View {
        contentWithModals
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(.colorBackgroundRaisedSecondary)
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(.hidden, for: .navigationBar)
            .toolbar { closeToolbarItem }
            .toolbar { agentShareToolbarItem }
            .task(id: contact.inboxId) { await syncBlockedState() }
            .task(id: contact.agentTemplateId) { await observeAgentTemplateConversations() }
            .task(id: contact.agentTemplateId) { await loadAgentDescription() }
            .onAppear {
                ensureNavigator()
                navState.markScreenAppeared()
            }
            .onDisappear {
                navigator?.closed(context: navState.closeContext())
            }
    }

    /// `bodyContent` plus the modal / sheet / overlay presentation layer.
    /// Split out of `body` so each modifier chain stays short enough for the
    /// type-checker (see the CLAUDE.md build-performance notes) as this view
    /// keeps accruing presentation surfaces.
    private var contentWithModals: some View {
        bodyContent
            .modifier(ContactDetailModalsModifier(
                presentingBlockConfirmation: $presentingBlockConfirmation,
                presentingPicker: $presentingPicker,
                presentingSendMessageError: $presentingSendMessageError,
                sendMessageErrorMessage: sendMessageErrorMessage,
                blockAlertTitle: blockAlertTitle,
                blockAlertMessage: blockAlertMessage,
                presentingAgentInfo: $presentingAgentInfo,
                onAgentInfoConfirm: { agentInfoConfirmed = true },
                onAgentInfoDismiss: handleAgentInfoDismiss,
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
            .navigationDestination(item: $pushedConversation) { vm in
                pushedConversationView(vm)
            }
            .overlay { agentShareOverlay }
    }

    /// Existing conversation pushed when a "Convos with you" row is tapped.
    /// `embedsNavigationStack: false` lands the view on the host stack with
    /// the system back button instead of nesting a second stack. The tab bar
    /// is hidden here (mirroring `ThingDetailView`) because the Contacts tab
    /// entry point pushes onto a tab stack whose shell only hides the bar for
    /// Chats/Things selections; without this the bar overlaps the composer.
    /// Harmless in sheet entry points, which have no tab bar.
    @ViewBuilder
    private func pushedConversationView(_ viewModel: NewConversationViewModel) -> some View {
        NewConversationView(
            viewModel: viewModel,
            profileSettingsViewModel: profileSettingsViewModel,
            embedsNavigationStack: false,
            insetsTopSafeArea: pushedConversationInsetsTopSafeArea
        )
        .background(.colorBackgroundSurfaceless)
        .toolbarVisibility(.hidden, for: .tabBar)
    }

    /// Streams conversations already containing this agent template,
    /// partitioned by who added the agent, from a database observation so
    /// the "Convos with you" sections stay live while the card is on screen
    /// (e.g. a convo spawned from this card's New chat appears without
    /// leaving the view). No-op for non-template contacts. The loop ends
    /// when the hosting `.task` is cancelled - the view disappears or the
    /// template id changes.
    private func observeAgentTemplateConversations() async {
        guard let session, let templateId = contact.agentTemplateId else {
            agentTemplateConversations = .empty
            return
        }
        let repository = session.conversationsRepository(for: [.allowed])
        let publisher = repository.conversationsPublisher(withAgentTemplateId: templateId)
        for await conversations in publisher.values {
            agentTemplateConversations = conversations
        }
    }

    /// Resolves the agent template's description (id or slug) so the card can
    /// show it under the name. `nil` for humans and when resolution fails.
    private func loadAgentDescription() async {
        // Suggested-agent contacts already carry the description (seeded in
        // init), so skip the round-trip; only saved agent contacts resolve it.
        guard agentDescription == nil, let session, let templateId = contact.agentTemplateId else { return }
        let info = await session.agentShareResolver().resolve(identifier: templateId)
        agentDescription = info?.descriptionText
    }

    /// Agent "code card" share flow: a QR encoding the template's published
    /// URL with the system share sheet behind it (mirrors the conversation
    /// "Convos code"). Replaces the plain share sheet so the toolbar button
    /// and the "Share" row both open the richer card.
    @ViewBuilder
    private var agentShareOverlay: some View {
        if presentingAgentShareSheet, let publishedURL = contact.agentTemplatePublishedURL {
            AgentShareOverlay(
                displayName: contact.resolvedDisplayName,
                emoji: contact.profileEmoji,
                publishedURLString: publishedURL,
                isPresented: $presentingAgentShareSheet
            )
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

    /// Share affordance for a template-backed agent. Shown only once the agent
    /// carries a published share link (`agentTemplateShareURL`, from its
    /// profile metadata or the persisted contact); tapping it presents the
    /// agent-share QR overlay. An agent with no `publishedUrl` can't be shared,
    /// so the button is hidden rather than offering an action that would fail -
    /// the backend is expected to populate the link for every template. It is
    /// also hidden while the overlay is up so it doesn't sit on top of the
    /// presented card.
    ///
    /// Styled with `.glassProminent` tinted to the primary color so it reads as
    /// a prominent black button with an inverse icon, matching the close
    /// button's glass treatment without a hand-rolled background.
    @ToolbarContentBuilder
    private var agentShareToolbarItem: some ToolbarContent {
        if agentTemplateShareURL != nil, !presentingAgentShareSheet {
            ToolbarItem(placement: .topBarTrailing) {
                let action = { presentingAgentShareSheet = true }
                Button(action: action) {
                    Image(systemName: "square.and.arrow.up")
                }
                .buttonStyle(.glassProminent)
                .tint(.colorFillPrimary)
                .accessibilityLabel("Share \(contact.resolvedDisplayName)")
                .accessibilityIdentifier("contact-detail-share-agent")
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
                if let agentDescription, !agentDescription.isEmpty {
                    Text(agentDescription)
                        .font(.body)
                        .foregroundStyle(.colorTextPrimary)
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.top, DesignConstants.Spacing.step2x)
                        .padding(.horizontal, DesignConstants.Spacing.step6x)
                }
                // Suggested-agent and agent-share placeholders aren't saved
                // contacts, so the "Added X ago" line (and Block, below)
                // don't apply.
                if !contact.isUnsavedAgentPlaceholder {
                    ContactDetailSubtitle(
                        contact: contact,
                        invitedBy: mode.invitedBy,
                        joinedAt: mode.joinedAt,
                        isBlocked: isBlocked
                    )
                    .padding(.top, DesignConstants.Spacing.step2x)
                }
                headerBadge
                if !ConfigManager.shared.currentEnvironment.isProduction, let variant = variantStamp {
                    ConversationVariantBanner(variant: variant)
                        .padding(.top, DesignConstants.Spacing.step6x)
                        .padding(.horizontal, DesignConstants.Spacing.step4x)
                }
                ContactDetailActions(
                    isBlocked: isBlocked,
                    isApplyingBlockChange: isApplyingBlockChange,
                    // A template-backed agent's Chat spawns a fresh instance
                    // into a new conversation (see `handleChatWithAgentTemplate`).
                    // A non-template verified agent gets a private DM with the
                    // existing instance when the agent-DM prototype is enabled
                    // (see `handleChatWithAgentDm`); otherwise its Chat CTA
                    // stays disabled and the agent rows below it remain the
                    // way to interact.
                    canSendMessage: session != nil && (!isVerifiedAgent || isAgentTemplate || canStartAgentDm),
                    showChat: !mode.isCurrentUser,
                    isAgent: isVerifiedAgent || isAgentTemplate,
                    showShare: agentTemplateShareURL != nil,
                    showRemove: mode.isScopedToConversation
                        && !mode.isCurrentUser
                        && mode.canRemoveMembers,
                    showBlock: !mode.isCurrentUser && !contact.isUnsavedAgentPlaceholder,
                    contactDisplayName: contact.resolvedDisplayName,
                    agentEmail: contact.agentEmail,
                    agentInstanceId: contact.agentInstanceId,
                    showsInstanceIdRow: showsInstanceIdRow,
                    agentAttestation: contact.agentAttestation,
                    agentVerification: contact.agentVerification,
                    agentTemplateConversations: agentTemplateConversations,
                    onSelectConversation: handleSelectAgentTemplateConversation,
                    onSendMessage: canStartAgentDm
                        ? handleChatWithAgentDm
                        : (isAgentTemplate ? handleChatWithAgentTemplate : handleSendMessage),
                    onShare: { presentingAgentShareSheet = true },
                    onRemove: handleRemoveTap,
                    onToggleBlock: handleBlockTap
                )
                .padding(.top, DesignConstants.Spacing.step8x)
            }
            .padding(.bottom, 80.0)
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
    ///
    /// Gated on `isVerifiedAgent` (a cryptographically-verified attestation
    /// that a sender cannot forge): `templateId`/`publishedUrl` are unsigned
    /// strings, and a snapshot from any member could in principle assert them
    /// for another contact, so the template affordance only trusts them on a
    /// verified agent.
    private var isAgentTemplate: Bool {
        contact.agentTemplateId != nil && contact.isVerifiedAgent
    }

    /// The template share link for a template-backed agent, ready for the
    /// Share row's `ShareLink`. `nil` for human contacts, for agents without a
    /// published template, and for unverified contacts (the published URL is
    /// unsigned metadata, so the share affordance is only trusted on a verified
    /// agent - see `isAgentTemplate`).
    private var agentTemplateShareURL: URL? {
        guard contact.isVerifiedAgent else { return nil }
        return contact.agentTemplatePublishedURL.flatMap { URL(string: $0) }
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
            RoleLabelPill(
                label: "You",
                accessibilityIdentifier: "contact-detail-you-badge"
            )
            .padding(.top, DesignConstants.Spacing.step2x)
        } else if let roleLabel = contact.agentVerification?.roleLabel {
            RoleLabelPill(
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
            suggestedAgentsService: SuggestedAgentsService.live(),
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

    /// Agent-DM prototype gate: a verified, non-template agent viewed from
    /// inside a shared conversation can be DM'd directly. Non-production
    /// only while the runtime side of agent DMs is in development.
    private var canStartAgentDm: Bool {
        session != nil
            && isVerifiedAgent
            && mode.isScopedToConversation
            && !ConfigManager.shared.currentEnvironment.isProduction
    }

    private func handleChatWithAgentDm() {
        guard let session else { return }
        Task {
            do {
                let conversationId = try await AgentDmFlow.startOrFindDm(
                    agentInboxId: contact.inboxId,
                    originConversationId: mode.conversationId,
                    session: session
                )
                await MainActor.run {
                    presentingNewConvo = NewConversationViewModel(
                        session: session,
                        mode: .existingConversation(conversationId: conversationId),
                        coreActions: coreActions
                    )
                }
            } catch {
                Log.error("Failed to start agent DM: \(error.localizedDescription)")
                await MainActor.run {
                    sendMessageErrorMessage = "We couldn't start a DM with this agent. Please try again."
                    presentingSendMessageError = true
                }
            }
        }
    }

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
                mode: .existingConversation(conversationId: existing.id),
                coreActions: coreActions
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
    private func handlePickerConfirm(_ memberInboxIds: Set<String>, _ agentTemplateIds: [String]) {
        guard !memberInboxIds.isEmpty || !agentTemplateIds.isEmpty, let session else { return }
        presentingNewConvo = NewConversationViewModel(
            session: session,
            mode: .newConversationWithMembers(
                initialMemberInboxIds: Array(memberInboxIds),
                initialAgentTemplateIds: agentTemplateIds
            ),
            coreActions: coreActions
        )
    }

    /// Chat action for a template-backed agent: spawn a fresh instance of
    /// the template into a new conversation. Presented locally via
    /// `presentingNewConvo`, the same sheet anchor `handlePickerConfirm`
    /// uses; the `.newConversationWithTemplate` mode creates the
    /// conversation and joins the agent once it reaches `.ready`.
    /// Chat with a template-backed agent shows the "New chat, new context"
    /// confirmation first; its "Got it" proceeds via `confirmChatWithAgentTemplate`
    /// (run from the sheet's `onDismiss` so the new-convo sheet presents after
    /// this one closes).
    private func handleChatWithAgentTemplate() {
        presentingAgentInfo = true
    }

    private func confirmChatWithAgentTemplate() {
        guard let session, let templateId = contact.agentTemplateId else { return }
        // The contact card already has the agent's identity in hand, so paint
        // it optimistically while the conversation provisions and the agent
        // joins -- no async resolve needed. `agentDescription` carries the
        // template description (seeded from the contact or resolved on
        // appear), so the optimistic contact card shows it instead of the
        // "Learning more about my job" placeholder while the agent joins.
        let optimisticIdentity = AgentShareInfo(
            templateId: templateId,
            displayName: contact.displayName,
            emoji: contact.profileEmoji,
            descriptionText: agentDescription,
            avatarURL: contact.avatarURL
        )
        presentingNewConvo = NewConversationViewModel(
            session: session,
            mode: .newConversationWithTemplate(templateId: templateId, optimisticIdentity: optimisticIdentity),
            coreActions: coreActions
        )
    }

    /// Opens an existing conversation from the "Convos with you" sections by
    /// pushing it onto the host navigation stack (all entry points wrap this
    /// view in a `NavigationStack`).
    private func handleSelectAgentTemplateConversation(_ conversation: Conversation) {
        guard let session else { return }
        pushedConversation = NewConversationViewModel(
            session: session,
            mode: .existingConversation(conversationId: conversation.id),
            coreActions: coreActions
        )
    }

    private func handleAgentInfoDismiss() {
        guard agentInfoConfirmed else { return }
        agentInfoConfirmed = false
        confirmChatWithAgentTemplate()
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
        // The scoped-mode "Invited X ago by Y" line reads as a footnote; the
        // standalone "Added X ago" keeps the subheadline size.
        let subtitleFont: Font = joinedAt != nil ? .footnote : .subheadline
        VStack(spacing: DesignConstants.Spacing.stepX) {
            Text(subtitleText)
                .font(subtitleFont)
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

/// Renders the "Convos with you" sections (template-backed agents only),
/// then the chat CTA ("New chat" for agents, "Chat" for human members),
/// Share, Remove, and Block - in that order. The chat CTA is the
/// primary CTA (filled dark pill); the rest use the secondary action-row
/// style (capsule label + caption below) so an agent and human card share
/// one row framework and only differ in which rows render.
private struct ContactDetailActions: View {
    let isBlocked: Bool
    let isApplyingBlockChange: Bool
    let canSendMessage: Bool
    let showChat: Bool
    /// Drives the chat CTA copy: "New chat" for agents (tapping spawns a
    /// fresh conversation), "Chat" for human members (tapping routes to a
    /// DM with that person).
    let isAgent: Bool
    let showShare: Bool
    let showRemove: Bool
    let showBlock: Bool
    let contactDisplayName: String
    /// Agent's email address from its profile metadata. Renders the
    /// "Contact Info" section under Share when present; nil (humans and
    /// older agents created before addresses were assigned) hides it.
    let agentEmail: String?
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
    /// Conversations already containing this agent template, rendered as the
    /// "Convos with you" / "someone else added" sections at the top of the
    /// action stack, above the New chat button.
    let agentTemplateConversations: AgentTemplateConversations
    /// Called with the conversation when a "Convos with you" row is tapped.
    let onSelectConversation: (Conversation) -> Void
    let onSendMessage: () -> Void
    let onShare: () -> Void
    let onRemove: () -> Void
    let onToggleBlock: () -> Void

    var body: some View {
        VStack(spacing: DesignConstants.Spacing.step6x) {
            if !agentTemplateConversations.isEmpty {
                AgentTemplateConversationsSections(
                    conversations: agentTemplateConversations,
                    onSelectConversation: onSelectConversation
                )
            }
            if showChat {
                chatButton
            }
            if showShare {
                shareRow
            }
            if let agentEmail {
                ContactDetailEmailSection(
                    email: agentEmail,
                    contactDisplayName: contactDisplayName
                )
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

    private var chatButton: some View {
        let backgroundOpacity: Double = canSendMessage ? 1.0 : 0.4
        let chatLabel: String = isAgent ? "New chat" : "Chat"
        return Button(action: onSendMessage) {
            Text(chatLabel)
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
        .accessibilityLabel("\(chatLabel) with \(contactDisplayName)")
        .accessibilityIdentifier("contact-detail-chat")
    }

    private var shareRow: some View {
        ContactDetailActionRow(
            label: "Share \(contactDisplayName)",
            footer: "Show a code or send a link to add this agent",
            color: .colorTextPrimary,
            isDisabled: false,
            accessibilityLabel: "Share \(contactDisplayName)",
            accessibilityIdentifier: "contact-detail-share-agent-row",
            action: onShare
        )
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

// MARK: - Contact Info section (agents with an email address)

/// The "Contact Info" section on an agent's contact card: a labeled card
/// with the agent's email address. Tapping the row opens the user's
/// default mail client via a `mailto:` link; the trailing button copies
/// the address and briefly swaps to a checkmark as confirmation. Rendered
/// only when the agent's profile metadata carries an email - older agents
/// created before the runtime assigned addresses don't have one. Header +
/// rounded-card shape mirrors `AgentTemplateConversationsSection`.
private struct ContactDetailEmailSection: View {
    let email: String
    let contactDisplayName: String

    @Environment(\.openURL) private var openURL: OpenURLAction
    @State private var didCopy: Bool = false

    var body: some View {
        VStack(alignment: .leading, spacing: DesignConstants.Spacing.step2x) {
            Text("Contact Info")
                .font(.footnote)
                .foregroundStyle(.colorTextSecondary)
                .padding(.leading, DesignConstants.Spacing.step2x)
            emailCard
        }
    }

    private var emailCard: some View {
        HStack(spacing: DesignConstants.Spacing.step2x) {
            emailButton
            copyButton
        }
        .padding(.vertical, DesignConstants.Spacing.step4x)
        .padding(.horizontal, DesignConstants.Spacing.step4x)
        .background(
            RoundedRectangle(cornerRadius: DesignConstants.CornerRadius.mediumLarge)
                .fill(.colorBackgroundRaised)
        )
    }

    private var emailButton: some View {
        let action = { openMailComposer() }
        return Button(action: action) {
            VStack(alignment: .leading, spacing: DesignConstants.Spacing.stepHalf) {
                Text(email)
                    .font(.callout.weight(.medium))
                    .foregroundStyle(.colorTextPrimary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text("Email")
                    .font(.footnote)
                    .foregroundStyle(.colorTextSecondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Email \(contactDisplayName) at \(email)")
        .accessibilityIdentifier("contact-detail-email")
    }

    private var copyButton: some View {
        let iconName: String = didCopy ? "checkmark" : "square.on.square"
        let iconColor: Color = didCopy ? .colorTextPrimary : .colorTextSecondary
        let label: String = didCopy ? "Copied" : "Copy email address"
        let action = { copyToClipboard() }
        return Button(action: action) {
            Image(systemName: iconName)
                .font(.title3)
                .foregroundStyle(iconColor)
                .frame(width: 44.0, height: 44.0)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
        .accessibilityIdentifier("contact-detail-email-copy")
    }

    private func openMailComposer() {
        guard let url = URL(string: "mailto:\(email)") else { return }
        openURL(url)
    }

    private func copyToClipboard() {
        UIPasteboard.general.string = email
        didCopy = true
        Task {
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            didCopy = false
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
    @Binding var presentingAgentInfo: Bool
    let onAgentInfoConfirm: () -> Void
    let onAgentInfoDismiss: () -> Void
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
            .selfSizingSheet(isPresented: $presentingAgentInfo, onDismiss: onAgentInfoDismiss) {
                OneAgentManyConvosInfoSheet(onConfirm: onAgentInfoConfirm)
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
        agentVerification: AgentVerification?,
        agentTemplateId: String? = nil,
        agentTemplatePublishedURL: String? = nil,
        profileEmoji: String? = nil,
        agentInstanceId: String? = nil,
        agentEmail: String? = nil
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
            agentInstanceId: agentInstanceId,
            agentEmail: agentEmail
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
    /// The agent-template `templateId`, `publishedUrl`, and `instanceId` are
    /// overlaid here from the freshest per-conversation member profile
    /// metadata onto whichever contact is returned. Without the `templateId`
    /// overlay `isAgentTemplate` is always false. `publishedUrl` falls back to
    /// the persisted contact value when the live metadata omits it - the agent
    /// runtime doesn't always carry the link, and overwriting a known URL with
    /// a nil would hide the Share button for an agent we already have a link for.
    public static func resolved(
        member: ConversationMember,
        in conversationId: String,
        contactsRepository: any ContactsRepositoryProtocol
    ) -> Contact {
        let templateId: String? = member.profile.agentTemplateId
        let templatePublishedURL: String? = member.profile.agentTemplatePublishedURL
        let emoji: String? = member.profile.profileEmoji
        let instanceId: String? = member.profile.agentInstanceId
        let email: String? = member.profile.agentEmail
        let attestation: String? = member.profile.agentAttestation
        if let stored = try? contactsRepository.fetchContact(inboxId: member.profile.inboxId) {
            let resolvedPublishedURL: String? = templatePublishedURL ?? stored.agentTemplatePublishedURL
            return stored
                .with(agentTemplateId: templateId)
                .with(agentTemplatePublishedURL: resolvedPublishedURL)
                .with(profileEmoji: emoji)
                .with(agentInstanceId: instanceId)
                .with(agentVerification: member.agentVerification)
                .with(agentEmail: email)
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
            agentInstanceId: instanceId,
            agentEmail: email
        )
        .with(agentAttestation: attestation)
    }
}

#Preview("Default") {
    NavigationStack {
        ContactDetailView(
            contact: .mock(displayName: "Alice"),
            contactsWriter: MockContactsWriter(),
            contactsRepository: MockContactsRepository(),
            coreActions: NoOpCoreActions()
        )
    }
}

#Preview("Blocked") {
    NavigationStack {
        ContactDetailView(
            contact: .mock(displayName: "Alice", isBlocked: true),
            contactsWriter: MockContactsWriter(),
            contactsRepository: MockContactsRepository(),
            coreActions: NoOpCoreActions()
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
            contactsRepository: MockContactsRepository(),
            coreActions: NoOpCoreActions()
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
            contactsRepository: MockContactsRepository(),
            coreActions: NoOpCoreActions()
        )
    }
}

#Preview("Agent template with email") {
    NavigationStack {
        ContactDetailView(
            contact: .mock(
                displayName: "Tifoso",
                agentVerification: .verified(.convos),
                agentTemplatePublishedURL: "https://agents-dev.convos.org/tifoso.pnw1o",
                agentEmail: "tifoso.123456@ai.convos.org"
            ),
            contactsWriter: MockContactsWriter(),
            contactsRepository: MockContactsRepository(),
            coreActions: NoOpCoreActions()
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
            contactsRepository: MockContactsRepository(),
            coreActions: NoOpCoreActions()
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
            coreActions: NoOpCoreActions(),
            onRemove: {}
        )
    }
}
