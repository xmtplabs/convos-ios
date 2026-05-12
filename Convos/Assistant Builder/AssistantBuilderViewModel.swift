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

    /// Set to true when the user taps Make. Until then the builder is in
    /// "draft" mode: the conversation indicator is non-interactive
    /// (renaming/re-imaging the draft happens *after* commit, in the
    /// post-morph `ConversationView`, not here).
    var hasCommitted: Bool = false

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
