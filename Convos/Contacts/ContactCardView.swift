import ConvosCore
import SwiftUI

// MARK: - Module overview
//
// `ContactCardView` is the single canonical "look at this person" surface
// in the app. It is invoked from two entry points, parameterized by
// `ContactCardMode`:
//
//   1. **Contacts list** (`ContactsView`) → `mode: .standalone`. Default.
//   2. **Member-avatar tap inside a chat** (`ConversationView` → presenting
//      `presentingProfileForMember`) → `mode: .scopedToConversation(...)`.
//
// Section visibility is driven by the mode plus the contact's stored state:
//
//   - Header (avatar / name) — always
//   - Agent rows (Get skills / Learn about assistants) — both modes, when
//     `contact.agentVerification?.isVerified == true`
//   - Send a message — both modes, calls `contactsWriter.upsertContact(...)`
//     before opening the picker so a synthetic / non-yet-stored contact is
//     promoted to a real one (the narrow per-person upsert documented in
//     the contacts PRD, "Send-message on a non-contact" section)
//   - Block / Unblock — both modes
//   - Group actions (Remove, Block-and-leave) — scoped mode only
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
    private let onBlockAndLeave: (() -> Void)?

    @State private var isBlocked: Bool
    @State private var isApplyingBlockChange: Bool = false
    @State private var presentingBlockConfirmation: Bool = false
    @State private var presentingBlockAndLeaveConfirmation: Bool = false
    @State private var presentingPicker: Bool = false
    @State private var presentingSendMessageError: Bool = false
    @State private var sendMessageErrorMessage: String?

    init(
        contact: Contact,
        mode: ContactCardMode = .standalone,
        contactsWriter: any ContactsWriterProtocol,
        contactsRepository: any ContactsRepositoryProtocol,
        session: (any SessionManagerProtocol)? = nil,
        onRemove: (() -> Void)? = nil,
        onBlockAndLeave: (() -> Void)? = nil
    ) {
        self.contact = contact
        self.mode = mode
        self.contactsWriter = contactsWriter
        self.contactsRepository = contactsRepository
        self.session = session
        self.onRemove = onRemove
        self.onBlockAndLeave = onBlockAndLeave
        _isBlocked = State(initialValue: contact.isBlocked)
    }

    var body: some View {
        bodyContent
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(.colorBackgroundRaisedSecondary)
            .navigationTitle("Contact")
            .navigationBarTitleDisplayMode(.inline)
            .modifier(ContactCardModalsModifier(
                presentingBlockConfirmation: $presentingBlockConfirmation,
                presentingBlockAndLeaveConfirmation: $presentingBlockAndLeaveConfirmation,
                presentingPicker: $presentingPicker,
                presentingSendMessageError: $presentingSendMessageError,
                sendMessageErrorMessage: sendMessageErrorMessage,
                blockAlertTitle: blockAlertTitle,
                blockAlertMessage: blockAlertMessage,
                blockAlertActions: { blockAlertActions },
                blockAndLeaveAlertTitle: blockAndLeaveAlertTitle,
                blockAndLeaveAlertMessage: blockAndLeaveAlertMessage,
                blockAndLeaveAlertActions: { blockAndLeaveAlertActions },
                pickerSheet: { pickerSheet }
            ))
            .task(id: contact.inboxId) { await syncBlockedState() }
    }

    @ViewBuilder
    private var bodyContent: some View {
        VStack(spacing: DesignConstants.Spacing.step3x) {
            ContactCardHeader(contact: contact)
            ContactCardMetadata(addedAt: contact.addedAt, isBlocked: isBlocked)
            if isVerifiedAgent {
                ContactCardAgentLinks()
            }
            ContactCardActions(
                isBlocked: isBlocked,
                isApplyingBlockChange: isApplyingBlockChange,
                canSendMessage: session != nil,
                onSendMessage: handleSendMessage,
                onToggleBlock: handleBlockTap
            )
            if mode.isScopedToConversation && !mode.isCurrentUser {
                ContactCardGroupActions(
                    canRemoveMembers: mode.canRemoveMembers,
                    contactDisplayName: contact.resolvedDisplayName,
                    onRemove: handleRemoveTap,
                    onBlockAndLeave: handleBlockAndLeaveTap
                )
            }
            Spacer()
        }
    }

    // MARK: - Derived

    private var isVerifiedAgent: Bool {
        contact.agentVerification?.isVerified == true
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

    // MARK: - Block-and-leave alert content

    private var blockAndLeaveAlertTitle: String {
        "Block \(contact.resolvedDisplayName) and leave convo?"
    }

    private var blockAndLeaveAlertMessage: String {
        "They won't know they're blocked, and you'll leave this conversation so they can't reach you here."
    }

    @ViewBuilder
    private var blockAndLeaveAlertActions: some View {
        Button("Cancel", role: .cancel) {}
        Button("Confirm", role: .destructive, action: handleBlockAndLeaveConfirmed)
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

    private func handleBlockAndLeaveTap() {
        presentingBlockAndLeaveConfirmation = true
    }

    private func handleBlockAndLeaveConfirmed() {
        onBlockAndLeave?()
    }

    private func applyBlockChange(block: Bool) {
        guard !isApplyingBlockChange else { return }
        isApplyingBlockChange = true
        let inboxId = contact.inboxId
        Task { @MainActor in
            defer { isApplyingBlockChange = false }
            do {
                if block {
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
                .frame(width: 96.0, height: 96.0)
                .padding(.top, DesignConstants.Spacing.step6x)

            Text(contact.resolvedDisplayName)
                .font(.title2.weight(.semibold))
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
            HStack {
                Text("Added")
                    .foregroundStyle(.colorTextSecondary)
                Spacer()
                Text(addedAt.formatted(date: .abbreviated, time: .omitted))
                    .foregroundStyle(.colorTextPrimary)
            }
            if isBlocked {
                blockedRow
            }
        }
        .font(.subheadline)
        .padding(DesignConstants.Spacing.step3x)
    }

    private var blockedRow: some View {
        HStack {
            Text("Status")
                .foregroundStyle(.colorTextSecondary)
            Spacer()
            HStack(spacing: 4.0) {
                Image(systemName: "nosign")
                Text("Blocked")
            }
            .foregroundStyle(.colorCaution)
        }
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
    let onSendMessage: () -> Void
    let onToggleBlock: () -> Void

    var body: some View {
        VStack(spacing: DesignConstants.Spacing.step2x) {
            sendMessageButton
            blockButton
        }
        .padding(.horizontal, DesignConstants.Spacing.step4x)
    }

    private var sendMessageButton: some View {
        let foreground: Color = canSendMessage ? .colorTextPrimaryInverted : .colorTextTertiary
        let background: Color = canSendMessage ? .colorTextPrimary : .colorFillMinimal
        return Button(action: onSendMessage) {
            Label("Send a message", systemImage: "paperplane.fill")
                .font(.body.weight(.semibold))
                .foregroundStyle(foreground)
                .frame(maxWidth: .infinity)
                .padding(.vertical, DesignConstants.Spacing.step3x)
                .background(
                    RoundedRectangle(cornerRadius: 22.0)
                        .fill(background)
                )
        }
        .disabled(!canSendMessage)
        .accessibilityIdentifier("contact-card-send-message")
    }

    private var blockButton: some View {
        let label: String = isBlocked ? "Unblock" : "Block"
        let foreground: Color = isBlocked ? .colorTextPrimary : .colorCaution
        return Button(action: onToggleBlock) {
            Text(label)
                .font(.body.weight(.medium))
                .foregroundStyle(foreground)
                .frame(maxWidth: .infinity)
                .padding(.vertical, DesignConstants.Spacing.step3x)
                .background(
                    RoundedRectangle(cornerRadius: 22.0)
                        .stroke(foreground.opacity(0.4), lineWidth: 1.0)
                )
        }
        .disabled(isApplyingBlockChange)
        .accessibilityIdentifier(isBlocked ? "contact-card-unblock" : "contact-card-block")
    }
}

// MARK: - Group actions (scoped mode only)

private struct ContactCardGroupActions: View {
    let canRemoveMembers: Bool
    let contactDisplayName: String
    let onRemove: () -> Void
    let onBlockAndLeave: () -> Void

    var body: some View {
        VStack(spacing: DesignConstants.Spacing.step2x) {
            if canRemoveMembers {
                groupActionRow(
                    label: "Remove from convo",
                    footer: "Remove \(contactDisplayName) from this conversation",
                    accessibilityLabel: "Remove \(contactDisplayName)",
                    accessibilityIdentifier: "remove-member-button",
                    action: onRemove
                )
            }
            groupActionRow(
                label: "Block and leave",
                footer: "Leave this convo and block \(contactDisplayName)",
                accessibilityLabel: "Block \(contactDisplayName)",
                accessibilityIdentifier: "block-member-button",
                action: onBlockAndLeave
            )
        }
        .padding(.horizontal, DesignConstants.Spacing.step4x)
        .padding(.top, DesignConstants.Spacing.step2x)
    }

    private func groupActionRow(
        label: String,
        footer: String,
        accessibilityLabel: String,
        accessibilityIdentifier: String,
        action: @escaping () -> Void
    ) -> some View {
        VStack(alignment: .leading, spacing: 4.0) {
            Button(action: action) {
                Text(label)
                    .font(.body)
                    .foregroundStyle(.colorCaution)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.vertical, DesignConstants.Spacing.step2x)
                    .padding(.horizontal, DesignConstants.Spacing.step3x)
                    .background(
                        RoundedRectangle(cornerRadius: 12.0).fill(.colorFillMinimal)
                    )
            }
            .accessibilityLabel(accessibilityLabel)
            .accessibilityIdentifier(accessibilityIdentifier)
            Text(footer)
                .font(.caption)
                .foregroundStyle(.colorTextSecondary)
                .padding(.horizontal, DesignConstants.Spacing.step3x)
        }
    }
}

// MARK: - Modals modifier

private struct ContactCardModalsModifier<
    BlockActions: View,
    BlockLeaveActions: View,
    PickerContent: View
>: ViewModifier {
    @Binding var presentingBlockConfirmation: Bool
    @Binding var presentingBlockAndLeaveConfirmation: Bool
    @Binding var presentingPicker: Bool
    @Binding var presentingSendMessageError: Bool
    let sendMessageErrorMessage: String?
    let blockAlertTitle: String
    let blockAlertMessage: String
    let blockAlertActions: () -> BlockActions
    let blockAndLeaveAlertTitle: String
    let blockAndLeaveAlertMessage: String
    let blockAndLeaveAlertActions: () -> BlockLeaveActions
    let pickerSheet: () -> PickerContent

    func body(content: Content) -> some View {
        content
            .alert(blockAlertTitle, isPresented: $presentingBlockConfirmation) {
                blockAlertActions()
            } message: {
                Text(blockAlertMessage)
            }
            .alert(blockAndLeaveAlertTitle, isPresented: $presentingBlockAndLeaveConfirmation) {
                blockAndLeaveAlertActions()
            } message: {
                Text(blockAndLeaveAlertMessage)
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
    /// Used by the chat-side `ContactCardView` entry points (member-avatar
    /// tap, members list) so the card renders uniformly for contact
    /// members and non-contact members. The synthetic fallback is
    /// promoted to a real contact when the user taps "Send a message".
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
            onRemove: {},
            onBlockAndLeave: {}
        )
    }
}
