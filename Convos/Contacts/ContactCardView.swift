import ConvosCore
import SwiftUI

/// Contact card with profile snapshot, "Send a message" CTA, and block /
/// unblock affordance. The card pulls live blocked-state from the contacts
/// repository so the toggle reflects post-write reality.
struct ContactCardView: View {
    let contact: Contact
    private let contactsWriter: any ContactsWriterProtocol
    private let contactsRepository: any ContactsRepositoryProtocol
    private let session: (any SessionManagerProtocol)?

    @State private var isBlocked: Bool
    @State private var isApplyingBlockChange: Bool = false
    @State private var presentingBlockConfirmation: Bool = false
    @State private var presentingPicker: Bool = false
    @State private var presentingStartErrorAlert: Bool = false
    @State private var startErrorMessage: String?
    @State private var starter: ContactConversationStarter?

    init(
        contact: Contact,
        contactsWriter: any ContactsWriterProtocol = MockContactsWriter(),
        contactsRepository: any ContactsRepositoryProtocol,
        session: (any SessionManagerProtocol)? = nil
    ) {
        self.contact = contact
        self.contactsWriter = contactsWriter
        self.contactsRepository = contactsRepository
        self.session = session
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
                presentingPicker: $presentingPicker,
                presentingStartErrorAlert: $presentingStartErrorAlert,
                startErrorMessage: startErrorMessage,
                blockAlertTitle: blockAlertTitle,
                blockAlertMessage: blockAlertMessage,
                blockAlertActions: { blockAlertActions },
                pickerSheet: { pickerSheet }
            ))
            .task(id: contact.inboxId) { await syncBlockedState() }
            .onAppear(perform: ensureStarter)
    }

    @ViewBuilder
    private var bodyContent: some View {
        VStack(spacing: DesignConstants.Spacing.step3x) {
            ContactCardHeader(contact: contact)
            ContactCardMetadata(addedAt: contact.addedAt, isBlocked: isBlocked)
            ContactCardActions(
                isBlocked: isBlocked,
                isApplyingBlockChange: isApplyingBlockChange,
                canSendMessage: session != nil,
                onSendMessage: handleSendMessage,
                onToggleBlock: handleBlockTap
            )
            Spacer()
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

    private func ensureStarter() {
        guard starter == nil, let session else { return }
        starter = ContactConversationStarter(session: session)
    }

    private func handleSendMessage() {
        ensureStarter()
        presentingPicker = true
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

    private func handlePickerConfirm(_ inboxIds: Set<String>) {
        guard let starter else { return }
        let ids = Array(inboxIds)
        Task { [starter] in
            do {
                try await starter.start(with: ids)
            } catch let typed as ContactConversationStarterError {
                presentStartError(typed.errorDescription)
            } catch {
                presentStartError(error.localizedDescription)
            }
        }
    }

    private func presentStartError(_ message: String?) {
        startErrorMessage = message ?? "Please try again."
        presentingStartErrorAlert = true
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
            ContactAvatarPlaceholder(seed: contact.inboxId, initial: monogram)
                .frame(width: 96.0, height: 96.0)
                .padding(.top, DesignConstants.Spacing.step6x)

            Text(contact.resolvedDisplayName)
                .font(.title2.weight(.semibold))
                .foregroundStyle(.colorTextPrimary)

            if let bio = contact.bio, !bio.isEmpty {
                Text(bio)
                    .font(.body)
                    .foregroundStyle(.colorTextSecondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, DesignConstants.Spacing.step4x)
            }
        }
    }

    private var monogram: String {
        let trimmed = contact.resolvedDisplayName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let first = trimmed.first else { return "?" }
        return String(first).uppercased()
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

// MARK: - Modals modifier

private struct ContactCardModalsModifier<Actions: View, PickerContent: View>: ViewModifier {
    @Binding var presentingBlockConfirmation: Bool
    @Binding var presentingPicker: Bool
    @Binding var presentingStartErrorAlert: Bool
    let startErrorMessage: String?
    let blockAlertTitle: String
    let blockAlertMessage: String
    let blockAlertActions: () -> Actions
    let pickerSheet: () -> PickerContent

    func body(content: Content) -> some View {
        content
            .alert(blockAlertTitle, isPresented: $presentingBlockConfirmation) {
                blockAlertActions()
            } message: {
                Text(blockAlertMessage)
            }
            .alert(
                "Couldn't start conversation",
                isPresented: $presentingStartErrorAlert,
                presenting: startErrorMessage
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

#Preview("Default") {
    NavigationStack {
        ContactCardView(
            contact: .mock(displayName: "Alice"),
            contactsRepository: MockContactsRepository()
        )
    }
}

#Preview("Blocked") {
    NavigationStack {
        ContactCardView(
            contact: .mock(displayName: "Alice", isBlocked: true),
            contactsRepository: MockContactsRepository()
        )
    }
}
