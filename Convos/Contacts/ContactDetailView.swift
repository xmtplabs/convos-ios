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
// Section visibility is driven by the mode plus the contact's stored state:
//
//   - Close (X) button - always, top-leading overlay
//   - Header (avatar / name / optional role-label capsule) - always
//   - Subtitle - "Invited X ago by Y" in scoped mode when the member has a
//     `joinedAt`; otherwise "Added X ago" from `contact.addedAt`
//   - Agent rows (Get skills / Learn about assistants) - both modes, when
//     `contact.agentVerification?.isVerified == true`
//   - Chat - both modes; calls `contactsWriter.upsertContact(...)`
//     before opening the picker so a synthetic / non-yet-stored contact is
//     promoted to a real one. Disabled for verified agents (no DMs yet).
//   - Remove - scoped mode only, when the viewer is an admin
//     (`canRemoveMembers`) and the tapped member is not the current user
//   - Block / Unblock - both modes (hidden for the current user)
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
    private let onRemove: (() -> Void)?

    @Environment(\.dismiss) private var dismiss: DismissAction
    @State private var isBlocked: Bool
    @State private var isApplyingBlockChange: Bool = false
    @State private var presentingBlockConfirmation: Bool = false
    @State private var presentingPicker: Bool = false
    @State private var presentingSendMessageError: Bool = false
    @State private var sendMessageErrorMessage: String?

    init(
        contact: Contact,
        mode: ContactDetailMode = .standalone,
        contactsWriter: any ContactsWriterProtocol,
        contactsRepository: any ContactsRepositoryProtocol,
        session: (any SessionManagerProtocol)? = nil,
        showsCloseButton: Bool = true,
        onRemove: (() -> Void)? = nil
    ) {
        self.contact = contact
        self.mode = mode
        self.contactsWriter = contactsWriter
        self.contactsRepository = contactsRepository
        self.session = session
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
        VStack(spacing: 0.0) {
            ContactDetailHeader(contact: contact)
                .padding(.top, 60.0)
            ContactDetailSubtitle(
                contact: contact,
                invitedBy: mode.invitedBy,
                joinedAt: mode.joinedAt,
                isBlocked: isBlocked
            )
            .padding(.top, DesignConstants.Spacing.step2x)
            if isVerifiedAgent {
                ContactDetailAgentLinks()
                    .padding(.top, DesignConstants.Spacing.step8x)
            }
            ContactDetailActions(
                isBlocked: isBlocked,
                isApplyingBlockChange: isApplyingBlockChange,
                // Verified agents (Convos / OAuth-verified) don't accept
                // 1:1 DMs today, so the Chat CTA would open a conversation
                // that goes nowhere. Disable until DM support for agents
                // lands; the "Get skills" / "Learn about assistants" rows
                // above remain the right way to interact.
                canSendMessage: session != nil && !isVerifiedAgent,
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
            Spacer(minLength: 0.0)
        }
    }

    // MARK: - Derived

    private var isVerifiedAgent: Bool {
        contact.isVerifiedAgent
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

private struct ContactDetailHeader: View {
    let contact: Contact

    var body: some View {
        VStack(spacing: DesignConstants.Spacing.step4x) {
            ContactAvatarView(contact: contact)
                .frame(width: 160.0, height: 160.0)

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
                    .accessibilityIdentifier("contact-detail-role-label-\(contact.inboxId)")
            }
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

// MARK: - Agent links

private struct ContactDetailAgentLinks: View {
    @Environment(\.openURL) private var openURL: OpenURLAction

    var body: some View {
        VStack(spacing: DesignConstants.Spacing.step2x) {
            agentLinkRow(
                title: "Get skills",
                subtitle: "Browse 100+ curated capabilities",
                url: AgentLinks.getSkillsURL,
                accessibilityIdentifier: "contact-detail-get-skills"
            )
            agentLinkRow(
                title: "Learn about assistants",
                subtitle: "Capabilities, privacy and security",
                url: AgentLinks.learnAboutAssistantsURL,
                accessibilityIdentifier: "contact-detail-learn-about-assistants"
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

// MARK: - Action stack

/// Renders Chat + (optional) Remove + (optional) Block in the order shown
/// in the design. Chat is the primary CTA (filled dark pill); Remove and
/// Block use the secondary action-row style (white pill + caption).
private struct ContactDetailActions: View {
    let isBlocked: Bool
    let isApplyingBlockChange: Bool
    let canSendMessage: Bool
    let showRemove: Bool
    let showBlock: Bool
    let contactDisplayName: String
    let onSendMessage: () -> Void
    let onRemove: () -> Void
    let onToggleBlock: () -> Void

    var body: some View {
        VStack(spacing: DesignConstants.Spacing.step6x) {
            chatButton
            if showRemove {
                removeRow
            }
            if showBlock {
                blockRow
            }
        }
        .padding(.horizontal, DesignConstants.Spacing.step4x)
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
