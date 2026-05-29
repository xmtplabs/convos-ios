import ConvosCore
import SwiftUI

/// Standalone contact card for a template-backed agent, opened by tapping
/// an agent row in the contacts list.
///
/// A deliberate sibling of `ContactDetailView` (which is built around the
/// human `Contact` type) rather than a generalization of it - the two
/// share the `ContactDetailActionRow` / `ContactDetailShareRow` building
/// blocks but keep their type models separate.
///
/// Actions:
///   - Share - the iOS share sheet seeded with the template `publishedUrl`.
///   - Pop up a convo - spawns a fresh instance via a local
///     `NewConversationViewModel` presentation, same path the chat-side
///     agent card uses (`ContactDetailView.handleChatWithAgentTemplate`).
///   - Remove - deletes the local agent-template contact row. If a shared
///     conversation still contains an instance, the next membership sync
///     re-adds it (the eventual-consistency story from the PRD).
struct AgentTemplateContactCardView: View {
    let agentTemplateContact: AgentTemplateContact
    private let agentTemplateContactsWriter: any AgentTemplateContactsWriterProtocol
    private let session: (any SessionManagerProtocol)?
    private let profileSettingsViewModel: ProfileSettingsViewModel

    @State private var presentingRemoveConfirmation: Bool = false
    @State private var isRemoving: Bool = false
    @State private var presentingNewConvo: NewConversationViewModel?
    @Environment(\.dismiss) private var dismiss: DismissAction

    init(
        agentTemplateContact: AgentTemplateContact,
        agentTemplateContactsWriter: any AgentTemplateContactsWriterProtocol,
        session: (any SessionManagerProtocol)? = nil,
        profileSettingsViewModel: ProfileSettingsViewModel = .shared
    ) {
        self.agentTemplateContact = agentTemplateContact
        self.agentTemplateContactsWriter = agentTemplateContactsWriter
        self.session = session
        self.profileSettingsViewModel = profileSettingsViewModel
    }

    var body: some View {
        bodyContent
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(.colorBackgroundRaisedSecondary)
            .navigationTitle("")
            .navigationBarTitleDisplayMode(.inline)
            .alert(removeAlertTitle, isPresented: $presentingRemoveConfirmation) {
                Button("Cancel", role: .cancel) {}
                Button("Remove", role: .destructive, action: handleRemoveConfirmed)
            } message: {
                Text(removeAlertMessage)
            }
            .sheet(item: $presentingNewConvo) { vm in
                NewConversationView(
                    viewModel: vm,
                    profileSettingsViewModel: profileSettingsViewModel
                )
                .background(.colorBackgroundSurfaceless)
            }
    }

    @ViewBuilder
    private var bodyContent: some View {
        VStack(spacing: DesignConstants.Spacing.step3x) {
            header
            actions
            Spacer()
        }
    }

    private var header: some View {
        VStack(spacing: DesignConstants.Spacing.step2x) {
            AgentTemplateAvatarView(
                agentTemplateContact: agentTemplateContact,
                emojiPointSize: 64.0
            )
            .frame(width: 140.0, height: 140.0)
            .padding(.top, DesignConstants.Spacing.step6x)

            Text(agentTemplateContact.resolvedDisplayName)
                .font(.largeTitle.weight(.bold))
                .foregroundStyle(.colorTextPrimary)

            RoleLabelPill(label: "Agent")

            if let description = agentTemplateContact.descriptionText, !description.isEmpty {
                Text(description)
                    .font(.subheadline)
                    .foregroundStyle(.colorTextSecondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, DesignConstants.Spacing.step6x)
            }
        }
    }

    @ViewBuilder
    private var actions: some View {
        VStack(spacing: DesignConstants.Spacing.step4x) {
            if let shareURL {
                ContactDetailShareRow(
                    url: shareURL,
                    contactDisplayName: agentTemplateContact.resolvedDisplayName
                )
            }
            ContactDetailActionRow(
                label: "Pop up a convo",
                footer: "Start a new convo with \(agentTemplateContact.resolvedDisplayName)",
                color: .colorTextPrimary,
                isDisabled: session == nil,
                accessibilityLabel: "Pop up a convo with \(agentTemplateContact.resolvedDisplayName)",
                accessibilityIdentifier: "agent-template-card-chat",
                action: handleChat
            )
            ContactDetailActionRow(
                label: "Remove",
                footer: "Remove \(agentTemplateContact.resolvedDisplayName) from your contacts",
                color: .colorCaution,
                isDisabled: isRemoving,
                accessibilityLabel: "Remove \(agentTemplateContact.resolvedDisplayName)",
                accessibilityIdentifier: "agent-template-card-remove",
                action: handleRemoveTap
            )
        }
        .padding(.horizontal, DesignConstants.Spacing.step4x)
        .padding(.top, DesignConstants.Spacing.step4x)
    }

    private var shareURL: URL? {
        agentTemplateContact.publishedURL.flatMap { URL(string: $0) }
    }

    private var removeAlertTitle: String {
        "Remove \(agentTemplateContact.resolvedDisplayName)?"
    }

    private var removeAlertMessage: String {
        "This removes the agent from your contacts. It re-appears if you're still in a conversation that has it."
    }

    /// Spawns a fresh instance of this template into a new conversation by
    /// presenting a `NewConversationViewModel` locally. The model's
    /// `.newConversationWithTemplate` mode creates the conversation and
    /// requests the agent join once it reaches `.ready`, the same path the
    /// chat-side agent card uses.
    private func handleChat() {
        guard let session else { return }
        presentingNewConvo = NewConversationViewModel(
            session: session,
            mode: .newConversationWithTemplate(templateId: agentTemplateContact.templateId)
        )
    }

    private func handleRemoveTap() {
        presentingRemoveConfirmation = true
    }

    private func handleRemoveConfirmed() {
        guard !isRemoving else { return }
        isRemoving = true
        let templateId = agentTemplateContact.templateId
        Task { @MainActor in
            defer { isRemoving = false }
            do {
                try await agentTemplateContactsWriter.remove(templateId: templateId)
                dismiss()
            } catch {
                Log.error("Failed to remove agent-template contact \(templateId): \(error.localizedDescription)")
            }
        }
    }
}

#Preview("Agent template card") {
    NavigationStack {
        AgentTemplateContactCardView(
            agentTemplateContact: .mock(
                displayName: "Tifoso",
                emoji: "🚴",
                descriptionText: "Pro cycling expert and race-day strategist.",
                publishedURL: "https://agents-dev.convos.org/tifoso.pnw1o"
            ),
            agentTemplateContactsWriter: MockAgentTemplateContactsWriter()
        )
    }
}
