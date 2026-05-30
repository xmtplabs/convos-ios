import ConvosCore
import SwiftUI
import UIKit

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
///     If the contact does not yet carry a `publishedURL` (builder-flow
///     templates land on the device without one), the row instead drives a
///     PATCH /api/v2/agent-templates/:id flipping the template to
///     `published`, persists the returned URL onto the contact, and
///     auto-presents the share sheet.
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

    // Share / publish state. `resolvedShareURL` is seeded from the contact's
    // published URL on appear and updated locally after a successful publish
    // so the row flips from publish-and-share to plain share without
    // waiting for the next contact sync.
    @State private var resolvedShareURL: URL?
    @State private var isPublishing: Bool = false
    @State private var isShareSheetPresented: Bool = false
    @State private var publishErrorMessage: String?

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
        let isPublishErrorPresented: Binding<Bool> = Binding(
            get: { publishErrorMessage != nil },
            set: { newValue in
                if !newValue { publishErrorMessage = nil }
            }
        )
        bodyContent
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(.colorBackgroundRaisedSecondary)
            .navigationTitle("")
            .navigationBarTitleDisplayMode(.inline)
            .onAppear(perform: seedShareURLIfNeeded)
            .alert(removeAlertTitle, isPresented: $presentingRemoveConfirmation) {
                Button("Cancel", role: .cancel) {}
                Button("Remove", role: .destructive, action: handleRemoveConfirmed)
            } message: {
                Text(removeAlertMessage)
            }
            .alert("Couldn't share", isPresented: isPublishErrorPresented) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(publishErrorMessage ?? "")
            }
            .sheet(item: $presentingNewConvo) { vm in
                NewConversationView(
                    viewModel: vm,
                    profileSettingsViewModel: profileSettingsViewModel
                )
                .background(.colorBackgroundSurfaceless)
            }
            .background(shareSheetPresenter)
    }

    @ViewBuilder
    private var shareSheetPresenter: some View {
        if let url = resolvedShareURL {
            ShareSheetPresenter(
                activityItems: [url],
                isPresented: $isShareSheetPresented
            )
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
            shareRow
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

    @ViewBuilder
    private var shareRow: some View {
        if let url = resolvedShareURL {
            ContactDetailShareRow(
                url: url,
                contactDisplayName: agentTemplateContact.resolvedDisplayName
            )
        } else {
            // Two-state share button: the "Share" label stays the same so a
            // user who has seen the published-state row recognises this row
            // as the share affordance. The footer carries the differentiator
            // - it hints at the publish step (which needs network), so a
            // user on a flaky connection sees the cause if it fails.
            let publishLabel: String = isPublishing ? "Sharing..." : "Share"
            let publishFooter: String = "Publish to share a link adding \(agentTemplateContact.resolvedDisplayName) to a convo"
            ContactDetailActionRow(
                label: publishLabel,
                footer: publishFooter,
                color: .colorTextPrimary,
                isDisabled: isPublishing || session == nil,
                accessibilityLabel: "Publish and share \(agentTemplateContact.resolvedDisplayName)",
                accessibilityIdentifier: "agent-template-card-publish-share",
                action: handlePublishAndShare
            )
        }
    }

    private func seedShareURLIfNeeded() {
        guard resolvedShareURL == nil else { return }
        resolvedShareURL = agentTemplateContact.publishedURL.flatMap { URL(string: $0) }
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

    private func handlePublishAndShare() {
        guard !isPublishing, let session else { return }
        let templateId = agentTemplateContact.templateId
        isPublishing = true
        Task { @MainActor in
            defer { isPublishing = false }
            do {
                let template = try await session.publishAgentTemplate(id: templateId)
                guard let urlString = template.publishedUrl,
                      let url = URL(string: urlString) else {
                    Log.error("publishAgentTemplate returned no publishedUrl for templateId=\(templateId), status=\(template.status), urlString=\(template.publishedUrl ?? "<nil>")")
                    publishErrorMessage = "Couldn't share right now, try again."
                    return
                }
                await persistPublishedURL(urlString)
                resolvedShareURL = url
                isShareSheetPresented = true
            } catch {
                Log.error("publishAgentTemplate failed for templateId=\(templateId): \(String(describing: error))")
                publishErrorMessage = "Couldn't share right now, try again."
            }
        }
    }

    private func persistPublishedURL(_ urlString: String) async {
        let snapshot = AgentTemplateContactSnapshot(
            displayName: agentTemplateContact.displayName,
            emoji: agentTemplateContact.emoji,
            descriptionText: agentTemplateContact.descriptionText,
            publishedURL: urlString,
            avatarURL: agentTemplateContact.avatarURL,
            agentVerification: agentTemplateContact.agentVerification,
            profileUpdatedAt: Date()
        )
        do {
            try await agentTemplateContactsWriter.upsert(
                templateId: agentTemplateContact.templateId,
                addedViaConversationId: agentTemplateContact.addedViaConversationId,
                profile: snapshot
            )
        } catch {
            // Persistence is a UX optimization; the in-memory
            // `resolvedShareURL` still drives the rest of this session.
            Log.error("Failed to persist publishedURL for templateId=\(agentTemplateContact.templateId): \(error.localizedDescription)")
        }
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

/// Thin UIActivityViewController wrapper for presenting the system share
/// sheet imperatively after the publish API call returns. Mirrors the
/// `ShareSheetPresenter` in `ConversationShareView.swift`; kept file-local
/// here so the agent-template card doesn't depend on the conversation
/// share overlay's other state.
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

#Preview("Agent template card - published") {
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

#Preview("Agent template card - unpublished") {
    NavigationStack {
        AgentTemplateContactCardView(
            agentTemplateContact: .mock(
                displayName: "Tifoso",
                emoji: "🚴",
                descriptionText: "Pro cycling expert and race-day strategist.",
                publishedURL: nil
            ),
            agentTemplateContactsWriter: MockAgentTemplateContactsWriter()
        )
    }
}
