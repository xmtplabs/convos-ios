import Combine
import ConvosCore
import ConvosLogging
import Foundation
import Observation
import SwiftUI

@MainActor
@Observable
final class AssistantBuilderViewModel: Identifiable {
    enum Phase: Equatable {
        case bootstrap
        case focus
        case stopped
    }

    let session: any SessionManagerProtocol

    private(set) var phase: Phase = .bootstrap
    private(set) var conversationId: String?
    private(set) var invite: Invite?
    private(set) var conversation: Conversation?
    private(set) var focusSession: DBFocusSession?
    private(set) var liveBubbles: [DBLiveBubble] = []

    /// Local-only draft. Wired to the streaming publisher in checkpoint #6.
    var draftText: String = ""

    /// True briefly after a non-self member's live text empties out, so the
    /// region layout can give that member's "final phrase" a moment of focus
    /// before snapping back to user-only. Wired in checkpoint #6.
    private(set) var othersRecentlyStopped: Bool = false

    /// Stable session id for the focus mode lifecycle of this builder instance.
    /// Sent on every FocusModeControl so receivers can correlate start/stop pairs.
    let focusSessionId: String = UUID().uuidString

    @ObservationIgnored
    private var dismissAction: DismissAction?

    @ObservationIgnored
    private var cancellables: Set<AnyCancellable> = []

    @ObservationIgnored
    private var messagingService: AnyMessagingService?

    @ObservationIgnored
    private var conversationStateManager: (any ConversationStateManagerProtocol)?

    @ObservationIgnored
    private var inboxAcquisitionTask: Task<Void, Never>?

    @ObservationIgnored
    private var stateObservationTask: Task<Void, Never>?

    @ObservationIgnored
    private var hasSentInitialFocusStart: Bool = false

    init(session: any SessionManagerProtocol) {
        self.session = session
        bootstrapConversation()
    }

    func setDismissAction(_ dismiss: DismissAction) {
        self.dismissAction = dismiss
    }

    func dismiss() {
        cleanUp()
        dismissAction?()
    }

    func copyInviteToPasteboard() -> Bool {
        guard let invite, !invite.urlSlug.isEmpty else { return false }
        UIPasteboard.general.string = invite.urlSlug
        return true
    }

    // MARK: - Live bubble derivations

    var focusedMemberLiveText: String {
        guard let focusedInboxId = focusSession?.focusedInboxId else { return "" }
        return liveBubbles.first(where: { $0.senderInboxId == focusedInboxId })?.text ?? ""
    }

    var othersLiveText: String {
        let myInboxId = currentInboxId
        let focusedInboxId = focusSession?.focusedInboxId
        return liveBubbles
            .filter { $0.senderInboxId != myInboxId && $0.senderInboxId != focusedInboxId }
            .map(\.text)
            .first(where: { !$0.isEmpty }) ?? ""
    }

    var othersAreTyping: Bool {
        !othersLiveText.isEmpty
    }

    /// Stub for checkpoint #5; checkpoint #6 will fire the streaming clear and
    /// reset draftText after the receiver delay.
    func handleReturnPressed() {
        draftText = ""
    }

    private var currentInboxId: String {
        switch messagingService?.state {
        case .authorized(let inboxId):
            return inboxId
        default:
            return ""
        }
    }

    // MARK: - Bootstrap

    private func bootstrapConversation() {
        inboxAcquisitionTask = Task { [weak self] in
            guard let self else { return }
            let (messagingService, existingId) = await session.prepareNewConversation()
            guard !Task.isCancelled else { return }
            self.messagingService = messagingService

            let stateManager: any ConversationStateManagerProtocol
            if let existingId {
                stateManager = messagingService.conversationStateManager(for: existingId)
            } else {
                stateManager = messagingService.conversationStateManager()
            }
            self.conversationStateManager = stateManager

            observeStateManager(stateManager)
            await createGroupConversation(via: stateManager)
        }
    }

    private func createGroupConversation(via stateManager: any ConversationStateManagerProtocol) async {
        do {
            try await stateManager.createConversation()
        } catch {
            Log.error("Failed to create assistant builder conversation: \(error.localizedDescription)")
        }
    }

    private func observeStateManager(_ stateManager: any ConversationStateManagerProtocol) {
        stateObservationTask = Task { [weak self, stateManager] in
            for await state in stateManager.stateSequence {
                guard let self else { return }
                if Task.isCancelled { return }
                await self.handle(stateManagerState: state)
            }
        }
    }

    @MainActor
    private func handle(stateManagerState state: ConversationStateMachine.State) async {
        switch state {
        case .ready(let result):
            guard conversationId != result.conversationId else { return }
            conversationId = result.conversationId
            attachRepositories(for: result.conversationId)
            await sendInitialFocusStartIfNeeded(for: result.conversationId)
        default:
            break
        }
    }

    private func attachRepositories(for conversationId: String) {
        let inviteRepo = session.inviteRepository(for: conversationId)
        inviteRepo.invitePublisher
            .receive(on: DispatchQueue.main)
            .sink { [weak self] invite in
                self?.invite = invite
            }
            .store(in: &cancellables)

        let conversationRepo = session.conversationRepository(for: conversationId)
        conversationRepo.conversationPublisher
            .receive(on: DispatchQueue.main)
            .sink { [weak self] conversation in
                guard let self else { return }
                self.conversation = conversation
                self.handleConversationMembersChanged()
            }
            .store(in: &cancellables)

        let focusRepo = session.focusSessionRepository(for: conversationId)
        focusRepo.latestSessionPublisher(in: conversationId)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] session in
                self?.handleFocusSessionChanged(to: session)
            }
            .store(in: &cancellables)
    }

    private func sendInitialFocusStartIfNeeded(for conversationId: String) async {
        guard !hasSentInitialFocusStart, let messagingService else { return }
        hasSentInitialFocusStart = true
        let payload = FocusModeControl(
            state: .start,
            focusedInboxId: nil,
            sessionId: focusSessionId
        )
        do {
            try await messagingService.sendFocusModeControl(payload, for: conversationId)
        } catch {
            Log.error("Failed sending initial FocusModeControl(.start): \(error.localizedDescription)")
        }
    }

    private func handleConversationMembersChanged() {
        guard let conversation,
              let conversationId,
              let messagingService else { return }
        let nonSelfMembers = conversation.members.filter { !$0.isCurrentUser }
        guard let firstAgent = nonSelfMembers.first else { return }

        // Promote a pending focus session to the newly-joined agent.
        guard let focusSession,
              focusSession.state == .started,
              focusSession.focusedInboxId == nil else { return }
        let payload = FocusModeControl(
            state: .start,
            focusedInboxId: firstAgent.profile.inboxId,
            sessionId: focusSession.sessionId
        )
        Task {
            do {
                try await messagingService.sendFocusModeControl(payload, for: conversationId)
            } catch {
                Log.error("Failed promoting focus to agent: \(error.localizedDescription)")
            }
        }
    }

    private func handleFocusSessionChanged(to session: DBFocusSession?) {
        focusSession = session
        guard let session else { return }
        switch session.state {
        case .started:
            phase = (session.focusedInboxId == nil) ? .bootstrap : .focus
            // Trigger possible promotion now that we have a session row to fill.
            handleConversationMembersChanged()
        case .stopped:
            phase = .stopped
        }
    }

    // MARK: - Cleanup

    private func cleanUp() {
        inboxAcquisitionTask?.cancel()
        stateObservationTask?.cancel()
        cancellables.removeAll()
    }
}
