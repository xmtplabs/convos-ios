import ConvosCore
import SwiftUI

// MARK: - Module overview
//
// `ContactCardView` is the single canonical "look at this person" surface
// in the app. It is invoked from two entry points, parameterized by
// `ContactCardMode`:
//
//   1. Contacts list (`ContactsView`) -> `mode: .standalone`. Default.
//   2. Member-avatar tap inside a chat (`ConversationView` presents
//      `presentingProfileForMember`) -> `mode: .scopedToConversation(...)`.
//
// Section visibility is driven by the mode plus the contact's stored state:
//
//   - Header (avatar / name) - always
//   - Agent rows (Get skills / Learn about assistants) - both modes, when
//     `contact.agentVerification?.isVerified == true`
//   - Share - both modes, when the contact is a template-backed agent
//     (`contact.agentTemplatePublishedURL != nil`); presents the system
//     share sheet seeded with the template's web link
//   - Pop up a convo - both modes. For a human contact it calls
//     `contactsWriter.upsertContact(...)` before opening the picker so a
//     synthetic / non-yet-stored contact is promoted to a real one (the
//     narrow per-person upsert documented in the contacts PRD,
//     "Send-message on a non-contact" section). For a template-backed
//     agent (`contact.agentTemplateId != nil`) it instead posts
//     `.contactsRequestedAgentTemplateConversation`, spawning a fresh
//     agent instance into a new conversation - the same path the
//     `convos://template/<id>` deeplink takes.
//   - Block / Unblock - both modes
//   - Remove from convo - scoped mode only, when the viewer is an admin
//     (`canRemoveMembers`) and the tapped member is not the current user
//
// Mirrors `ContactsPickerMode`'s "one component, two entry points" pattern.

/// Unified contact card. See module-overview comment above for entry-point
/// mapping and section visibility rules.
struct ContactCardView: View {
    let contact: Contact
    let mode: ContactCardMode
    private let contactsWriter: any ContactsWriterProtocol
    private let contactsRepository: any ContactsRepositoryProtocol
    private let session: (any SessionManagerProtocol)?
    private let onRemove: (() -> Void)?

    @State private var isBlocked: Bool
    @State private var isApplyingBlockChange: Bool = false
    @State private var presentingBlockConfirmation: Bool = false
    @State private var presentingPicker: Bool = false
    @State private var presentingSendMessageError: Bool = false
    @State private var sendMessageErrorMessage: String?

    init(
        contact: Contact,
        mode: ContactCardMode = .standalone,
        contactsWriter: any ContactsWriterProtocol,
        contactsRepository: any ContactsRepositoryProtocol,
        session: (any SessionManagerProtocol)? = nil,
        onRemove: (() -> Void)? = nil
    ) {
        self.contact = contact
        self.mode = mode
        self.contactsWriter = contactsWriter
        self.contactsRepository = contactsRepository
        self.session = session
        self.onRemove = onRemove
        _isBlocked = State(initialValue: contact.isBlocked)
    }

    var body: some View {
        bodyContent
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(.colorBackgroundRaisedSecondary)
            .navigationTitle("")
            .navigationBarTitleDisplayMode(.inline)
            .modifier(ContactCardModalsModifier(
                presentingBlockConfirmation: $presentingBlockConfirmation,
                presentingPicker: $presentingPicker,
                presentingSendMessageError: $presentingSendMessageError,
                sendMessageErrorMessage: sendMessageErrorMessage,
                blockAlertTitle: blockAlertTitle,
                blockAlertMessage: blockAlertMessage,
                blockAlertActions: { blockAlertActions },
                pickerSheet: { pickerSheet }
            ))
            .task(id: contact.inboxId) { await syncBlockedState() }
    }

    @ViewBuilder
    private var bodyContent: some View {
        VStack(spacing: DesignConstants.Spacing.step3x) {
            VStack(spacing: DesignConstants.Spacing.stepX) {
                ContactCardHeader(contact: contact)
                ContactCardMetadata(addedAt: contact.addedAt, isBlocked: isBlocked)
            }
            if isVerifiedAgent {
                ContactCardAgentLinks()
            }
            ContactCardActions(
                isBlocked: isBlocked,
                isApplyingBlockChange: isApplyingBlockChange,
                // Verified agents (Convos / OAuth-verified) don't accept
                // 1:1 DMs today, so for a non-template verified agent the
                // Pop-up-a-convo CTA would open a conversation that goes
                // nowhere - keep it disabled. A template-backed agent
                // overrides this: the row spawns a fresh instance instead
                // (see `isAgentTemplate` / `handleChatWithAgentTemplate`).
                canSendMessage: session != nil && !isVerifiedAgent,
                isAgentTemplate: isAgentTemplate,
                contactDisplayName: contact.resolvedDisplayName,
                agentTemplateShareURL: agentTemplateShareURL,
                onSendMessage: handleSendMessage,
                onChatWithAgentTemplate: handleChatWithAgentTemplate,
                onToggleBlock: handleBlockTap
            )
            if mode.isScopedToConversation && !mode.isCurrentUser && mode.canRemoveMembers {
                ContactCardGroupActions(
                    contactDisplayName: contact.resolvedDisplayName,
                    onRemove: handleRemoveTap
                )
            }
            Spacer()
        }
    }

    // MARK: - Derived

    private var isVerifiedAgent: Bool {
        contact.isVerifiedAgent
    }

    /// True when this contact is a template-backed agent - it carries the
    /// `templateId` needed to spawn a fresh instance. Drives the
    /// Pop-up-a-convo row's behavior (spawn vs. open the picker).
    private var isAgentTemplate: Bool {
        contact.agentTemplateId != nil
    }

    /// The template share link for a template-backed agent, ready for the
    /// Share row's `ShareLink`. `nil` for human contacts and for agents
    /// without a published template, which hides the row.
    private var agentTemplateShareURL: URL? {
        contact.agentTemplatePublishedURL.flatMap { URL(string: $0) }
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
                presentingPicker = true
            }
        }
    }

    /// Spawn-and-join for a template-backed agent. Posts
    /// `.contactsRequestedAgentTemplateConversation`; `ConversationsViewModel`
    /// picks it up and routes into a fresh conversation with a new
    /// instance of the template - the same path the
    /// `convos://template/<id>` deeplink takes. The containing
    /// contact-card sheet is torn down by `ConversationView`'s `.onReceive`
    /// for the same notification.
    private func handleChatWithAgentTemplate() {
        guard let templateId = contact.agentTemplateId else { return }
        NotificationCenter.default.post(
            name: .contactsRequestedAgentTemplateConversation,
            object: nil,
            userInfo: ["templateId": templateId]
        )
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

    /// Forwards the picked inbox IDs to the conversations layer via
    /// notification; that layer constructs a `NewConversationViewModel`
    /// in `.newConversationWithMembers` mode so the placeholder UI shows
    /// immediately and the state machine folds `addMembers` into its
    /// create sequence atomically.
    private func handlePickerConfirm(_ inboxIds: Set<String>) {
        guard !inboxIds.isEmpty else { return }
        let ids = Array(inboxIds)
        NotificationCenter.default.post(
            name: .contactsRequestedNewConversation,
            object: nil,
            userInfo: ["inboxIds": ids]
        )
    }

    private func syncBlockedState() async {
        guard let updated = try? contactsRepository.fetchContact(inboxId: contact.inboxId) else {
            return
        }
        isBlocked = updated.isBlocked
    }
}

// MARK: - Header

private struct ContactCardHeader: View {
    let contact: Contact

    var body: some View {
        VStack(spacing: DesignConstants.Spacing.step2x) {
            ContactAvatarView(contact: contact)
                .frame(width: 140.0, height: 140.0)
                .padding(.top, DesignConstants.Spacing.step6x)

            Text(contact.resolvedDisplayName)
                .font(.largeTitle.weight(.bold))
                .foregroundStyle(.colorTextPrimary)

            if let roleLabel = contact.agentVerification?.roleLabel {
                Text(roleLabel)
                    .font(.footnote)
                    .foregroundStyle(.colorTextSecondary)
                    .padding(.horizontal, DesignConstants.Spacing.step2x)
                    .padding(.vertical, DesignConstants.Spacing.stepX)
                    .background(.colorTextSecondary.opacity(0.1), in: .capsule)
                    .accessibilityIdentifier("contact-card-role-label-\(contact.inboxId)")
            }
        }
    }
}

// MARK: - Metadata

private struct ContactCardMetadata: View {
    let addedAt: Date
    let isBlocked: Bool

    var body: some View {
        VStack(spacing: DesignConstants.Spacing.stepX) {
            Text("Added \(relativeAddedAt)")
                .foregroundStyle(.colorTextSecondary)
            if isBlocked {
                blockedRow
            }
        }
        .font(.subheadline)
        .frame(maxWidth: .infinity)
        .padding(.horizontal, DesignConstants.Spacing.step3x)
    }

    /// Mirrors the `RelativeDateTimeFormatter(.abbreviated)` convention from
    /// `ConversationMemberView`'s "Added X by Y" subtitle so the contact card
    /// reads the same way ("Added 20m ago", "Added 3h ago", "Added 2w ago").
    private var relativeAddedAt: String {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .abbreviated
        return formatter.localizedString(for: addedAt, relativeTo: Date())
    }

    private var blockedRow: some View {
        HStack(spacing: 4.0) {
            Image(systemName: "nosign")
            Text("Blocked")
        }
        .foregroundStyle(.colorCaution)
    }
}

// MARK: - Agent links

private struct ContactCardAgentLinks: View {
    @Environment(\.openURL) private var openURL: OpenURLAction

    var body: some View {
        VStack(spacing: DesignConstants.Spacing.step2x) {
            agentLinkRow(
                title: "Get skills",
                subtitle: "Browse 100+ curated capabilities",
                url: AgentLinks.getSkillsURL,
                accessibilityIdentifier: "contact-card-get-skills"
            )
            agentLinkRow(
                title: "Learn about assistants",
                subtitle: "Capabilities, privacy and security",
                url: AgentLinks.learnAboutAssistantsURL,
                accessibilityIdentifier: "contact-card-learn-about-assistants"
            )
        }
        .padding(.horizontal, DesignConstants.Spacing.step3x)
    }

    private func agentLinkRow(
        title: String,
        subtitle: String,
        url: URL,
        accessibilityIdentifier: String
    ) -> some View {
        let action = { openURL(url) }
        return Button(action: action) {
            HStack {
                VStack(alignment: .leading, spacing: 2.0) {
                    Text(title)
                        .font(.body)
                        .foregroundStyle(.colorTextPrimary)
                    Text(subtitle)
                        .font(.caption)
                        .foregroundStyle(.colorTextSecondary)
                }
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(.colorTextTertiary)
            }
            .padding(DesignConstants.Spacing.step3x)
            .background(
                RoundedRectangle(cornerRadius: 12.0).fill(.colorFillMinimal)
            )
        }
        .accessibilityIdentifier(accessibilityIdentifier)
    }
}

// MARK: - Action buttons

private struct ContactCardActions: View {
    let isBlocked: Bool
    let isApplyingBlockChange: Bool
    let canSendMessage: Bool
    /// When true, the Pop-up-a-convo row spawns a fresh agent instance
    /// (`onChatWithAgentTemplate`) instead of opening the contacts picker;
    /// the row is always enabled in this case.
    let isAgentTemplate: Bool
    let contactDisplayName: String
    /// Non-nil only for template-backed agents; drives the Share row.
    let agentTemplateShareURL: URL?
    let onSendMessage: () -> Void
    let onChatWithAgentTemplate: () -> Void
    let onToggleBlock: () -> Void

    var body: some View {
        VStack(spacing: DesignConstants.Spacing.step4x) {
            if let agentTemplateShareURL {
                ContactCardShareRow(
                    url: agentTemplateShareURL,
                    contactDisplayName: contactDisplayName
                )
            }
            popUpConvoRow
            blockRow
        }
        .padding(.horizontal, DesignConstants.Spacing.step4x)
        .padding(.top, DesignConstants.Spacing.step4x)
    }

    private var popUpConvoRow: some View {
        let footer: String = isAgentTemplate
            ? "Start a new convo with \(contactDisplayName)"
            : "Message \(contactDisplayName)"
        let identifier: String = isAgentTemplate
            ? "contact-card-chat-agent-template"
            : "contact-card-send-message"
        let isDisabled: Bool = isAgentTemplate ? false : !canSendMessage
        let action: () -> Void = isAgentTemplate ? onChatWithAgentTemplate : onSendMessage
        return ContactCardActionRow(
            label: "Pop up a convo",
            footer: footer,
            color: .colorTextPrimary,
            isDisabled: isDisabled,
            accessibilityLabel: "Pop up a convo with \(contactDisplayName)",
            accessibilityIdentifier: identifier,
            action: action
        )
    }

    private var blockRow: some View {
        let label: String = isBlocked ? "Unblock" : "Block"
        let footer: String = isBlocked
            ? "Start receiving convo invites from \(contactDisplayName) again"
            : "Block all future convo invites from \(contactDisplayName)"
        let identifier: String = isBlocked ? "contact-card-unblock" : "contact-card-block"
        return ContactCardActionRow(
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

// MARK: - Group actions (scoped mode only)

/// Renders conversation-scoped actions on the contact card. Today only
/// "Remove" lives here; it appears when the viewer is an admin who can
/// remove the tapped member. The plain Block row (above, in
/// `ContactCardActions`) covers the block intent in every mode, so this
/// view stays focused on conversation-scope-specific affordances.
private struct ContactCardGroupActions: View {
    let contactDisplayName: String
    let onRemove: () -> Void

    var body: some View {
        ContactCardActionRow(
            label: "Remove",
            footer: "Remove \(contactDisplayName) from the convo",
            color: .colorCaution,
            isDisabled: false,
            accessibilityLabel: "Remove \(contactDisplayName)",
            accessibilityIdentifier: "remove-member-button",
            action: onRemove
        )
        .padding(.horizontal, DesignConstants.Spacing.step4x)
        .padding(.top, DesignConstants.Spacing.step2x)
    }
}

// MARK: - Shared action row

/// Reusable row used by both `ContactCardActions` (Pop up a convo, Block)
/// and `ContactCardGroupActions` (Remove, Block and leave). The shape -
/// rounded white pill on top with a small grey footer caption below - is
/// the canonical card action style. The label color is the only knob: dark
/// primary for affirmative actions, caution red for destructive.
private struct ContactCardActionRow: View {
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
                    .font(.body.weight(.medium))
                    .foregroundStyle(color)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.vertical, DesignConstants.Spacing.step4x)
                    .padding(.horizontal, DesignConstants.Spacing.step3x)
                    .background(
                        RoundedRectangle(cornerRadius: 12.0).fill(.colorFillMinimal)
                    )
            }
            .buttonStyle(.plain)
            .disabled(isDisabled)
            .accessibilityLabel(accessibilityLabel)
            .accessibilityIdentifier(accessibilityIdentifier)
            Text(footer)
                .font(.caption)
                .foregroundStyle(.colorTextSecondary)
                .padding(.horizontal, DesignConstants.Spacing.step3x)
        }
    }
}

// MARK: - Share row (template-backed agents)

/// Share row for a template-backed agent. Mirrors `ContactCardActionRow`'s
/// pill-plus-footer shape, but wraps a SwiftUI `ShareLink` (which presents
/// the system share sheet) rather than a plain action button, since the
/// share intent is fully handled by the system. Rendered only when the
/// agent carries a template `publishedUrl`.
private struct ContactCardShareRow: View {
    let url: URL
    let contactDisplayName: String

    var body: some View {
        VStack(alignment: .leading, spacing: DesignConstants.Spacing.stepX) {
            ShareLink(item: url) {
                Text("Share")
                    .font(.body.weight(.medium))
                    .foregroundStyle(.colorTextPrimary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.vertical, DesignConstants.Spacing.step4x)
                    .padding(.horizontal, DesignConstants.Spacing.step3x)
                    .background(
                        RoundedRectangle(cornerRadius: 12.0).fill(.colorFillMinimal)
                    )
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Share \(contactDisplayName)")
            .accessibilityIdentifier("contact-card-share-agent-template")
            Text("Share a link to add \(contactDisplayName) to a convo")
                .font(.caption)
                .foregroundStyle(.colorTextSecondary)
                .padding(.horizontal, DesignConstants.Spacing.step3x)
        }
    }
}

// MARK: - Modals modifier

private struct ContactCardModalsModifier<
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
    /// taps "Send a message", at which point the writer's idempotent upsert
    /// promotes the synthetic to a real contact attributed to the source
    /// conversation.
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
        agentTemplatePublishedURL: String? = nil
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
            agentTemplatePublishedURL: agentTemplatePublishedURL
        )
    }

    /// Resolves the contact for `member.profile.inboxId`: returns the
    /// stored `Contact` if the inbox is a known contact, otherwise a
    /// synthetic one built from the member's profile snapshot.
    ///
    /// Used by the chat-side `ContactCardView` entry points (member-avatar
    /// tap, members list) so the card renders uniformly for contact
    /// members and non-contact members. The synthetic fallback is
    /// promoted to a real contact when the user taps "Send a message".
    ///
    /// The agent-template `templateId` and `publishedUrl` live only in the
    /// per-conversation member profile metadata (`DBContact` has no
    /// template column), so they are overlaid here onto whichever contact
    /// is returned - stored or synthetic - from the freshest source.
    public static func resolved(
        member: ConversationMember,
        in conversationId: String,
        contactsRepository: any ContactsRepositoryProtocol
    ) -> Contact {
        let templateId: String? = member.profile.agentTemplateId
        let templatePublishedURL: String? = member.profile.agentTemplatePublishedURL
        if let stored = try? contactsRepository.fetchContact(inboxId: member.profile.inboxId) {
            return stored
                .with(agentTemplateId: templateId)
                .with(agentTemplatePublishedURL: templatePublishedURL)
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
            agentTemplatePublishedURL: templatePublishedURL
        )
    }
}

#Preview("Default") {
    NavigationStack {
        ContactCardView(
            contact: .mock(displayName: "Alice"),
            contactsWriter: MockContactsWriter(),
            contactsRepository: MockContactsRepository()
        )
    }
}

#Preview("Blocked") {
    NavigationStack {
        ContactCardView(
            contact: .mock(displayName: "Alice", isBlocked: true),
            contactsWriter: MockContactsWriter(),
            contactsRepository: MockContactsRepository()
        )
    }
}

#Preview("Verified agent") {
    NavigationStack {
        ContactCardView(
            contact: .mock(
                displayName: "Convos Assistant",
                agentVerification: .verified(.convos)
            ),
            contactsWriter: MockContactsWriter(),
            contactsRepository: MockContactsRepository()
        )
    }
}

#Preview("Agent template") {
    NavigationStack {
        ContactCardView(
            contact: .mock(
                displayName: "Tifoso",
                agentVerification: .verified(.convos),
                agentTemplateId: "200e27dc-badc-429f-a431-b01b0281ec95",
                agentTemplatePublishedURL: "https://agents-dev.convos.org/tifoso.pnw1o"
            ),
            contactsWriter: MockContactsWriter(),
            contactsRepository: MockContactsRepository()
        )
    }
}

#Preview("Scoped to conversation, admin") {
    NavigationStack {
        ContactCardView(
            contact: .mock(displayName: "Bob"),
            mode: .scopedToConversation(
                conversationId: "convo-1",
                canRemoveMembers: true,
                isCurrentUser: false
            ),
            contactsWriter: MockContactsWriter(),
            contactsRepository: MockContactsRepository(),
            onRemove: {}
        )
    }
}
