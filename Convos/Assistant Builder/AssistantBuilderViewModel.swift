import ConvosCore
import Foundation
import Observation
import SwiftUI

@MainActor
@Observable
final class AssistantBuilderViewModel: Identifiable {
    let id: UUID = UUID()
    let session: any SessionManagerProtocol

    let newConversationViewModel: NewConversationViewModel

    var composerText: String = ""
    var pendingMediaAttachments: [PendingMediaAttachment] = []

    @ObservationIgnored
    private var assistantJoinTask: Task<Void, Never>?
    @ObservationIgnored
    private var didRequestAgentJoin: Bool = false

    init(session: any SessionManagerProtocol) {
        self.session = session
        self.newConversationViewModel = NewConversationViewModel(
            session: session,
            mode: .newAssistant
        )
        self.newConversationViewModel.onReachedReady = { [weak self] in
            self?.requestAgentJoinIfNeeded()
        }
    }

    deinit {
        assistantJoinTask?.cancel()
    }

    // MARK: - Composer mutations

    func removeAttachment(id: UUID) {
        pendingMediaAttachments.removeAll { $0.id == id }
    }

    // MARK: - Derived state

    /// Make button is enabled as soon as the composer has any content.
    /// Tapping Make before the state machine reaches `.ready` is fine —
    /// the morph animates the user into `ConversationView`, which surfaces
    /// its own "Assistant is joining…" state, and the message is queued
    /// via `ConversationStateMachine.sendMessage` (which already
    /// serializes against `.ready`).
    var isMakeEnabled: Bool {
        !composerText.isEmpty
    }

    /// True when the user has typed something or attached anything.
    /// The X button uses this to decide whether to confirm dismissal
    /// (Continue / Discard) or to silently discard.
    var hasContent: Bool {
        !composerText.isEmpty || !pendingMediaAttachments.isEmpty
    }

    /// Set to true when the user taps Make. Until then the builder is in
    /// "draft" mode: the conversation indicator is non-interactive
    /// (renaming/re-imaging the draft happens *after* commit, in the
    /// post-morph `ConversationView`, not here).
    var hasCommitted: Bool = false

    /// Phase A of the Make animation: text/attachments inside the composer
    /// fade out before the rounded rect itself disappears. Set true at the
    /// moment of Make tap, true through the rest of the commit (so the
    /// content stays hidden if the user re-enters the view somehow).
    var isCommitting: Bool = false

    // MARK: - Commit

    /// Tap-Make handler. Drives the staged commit animation:
    /// - Phase A (immediately): `isCommitting = true` so the composer's
    ///   content (text, attachments) fades out inside the rounded rect.
    /// - Phase B (after `Constant.contentFadeMs`): `hasCommitted = true`
    ///   so the overlay (rect + backdrop) fades and the underlying
    ///   `ConversationView` is revealed.
    ///
    /// The composer text is sent fire-and-forget at the start of Phase A —
    /// if the state machine hasn't reached `.ready`, the existing message-
    /// stream queue inside `ConversationStateMachine.sendMessage` holds
    /// the message until it does, so this never blocks the UI.
    func commit() {
        guard !hasCommitted, !isCommitting else { return }
        isCommitting = true

        let textToSend = composerText
        composerText = ""

        if !textToSend.isEmpty {
            Task { [newConversationViewModel] in
                do {
                    try await newConversationViewModel.send(text: textToSend)
                } catch {
                    Log.error("AssistantBuilder commit: send failed: \(error.localizedDescription)")
                }
            }
        }

        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(Constant.contentFadeMs))
            guard let self else { return }
            withAnimation(.easeInOut(duration: 0.35)) {
                self.hasCommitted = true
            }
        }
    }

    private enum Constant {
        static let contentFadeMs: Int = 180
    }

    // MARK: - Dismiss cleanup

    /// Tear down the in-flight draft. Cancels conversation-creation tasks
    /// and the agent-join request, and — if the conversation became real
    /// and the assistant has already joined — sets consent to denied so
    /// the assistant sees us depart. Local conversation row cleanup is
    /// handled by the draft repository when this VM deallocates.
    func discard() {
        assistantJoinTask?.cancel()
        didRequestAgentJoin = true // suppress any late retries

        let conversation = newConversationViewModel.conversationViewModel?.conversation
        let assistantJoined = conversation?.hasAgent ?? false

        newConversationViewModel.dismissWithDeletion()

        guard let conversation,
              !conversation.isDraft,
              assistantJoined else { return }

        Task { [session] in
            do {
                let writer = session.messagingService().conversationConsentWriter()
                try await writer.delete(conversation: conversation)
            } catch {
                Log.error("AssistantBuilder discard: failed to leave conversation \(conversation.id): \(error.localizedDescription)")
            }
        }
    }

    // MARK: - Assistant join

    private func requestAgentJoinIfNeeded() {
        guard !didRequestAgentJoin else { return }
        guard let conversation = newConversationViewModel.conversationViewModel?.conversation else {
            Log.warning("AssistantBuilderViewModel: reached .ready but no conversation available")
            return
        }
        let slug = conversation.invite?.urlSlug ?? ""
        guard !slug.isEmpty else {
            Log.warning("AssistantBuilderViewModel: reached .ready but invite slug is empty")
            return
        }
        didRequestAgentJoin = true

        assistantJoinTask?.cancel()
        assistantJoinTask = Task { [session] in
            do {
                _ = try await session.requestAgentJoin(
                    slug: slug,
                    instructions: "You're a Convos Assistant"
                )
            } catch is CancellationError {
                return
            } catch {
                Log.error("AssistantBuilderViewModel: requestAgentJoin failed: \(error.localizedDescription)")
            }
        }
    }
}
