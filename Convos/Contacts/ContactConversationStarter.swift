import ConvosCore
import ConvosInvites
import Foundation
import Observation

/// Errors that can surface when starting a new conversation from selected
/// contacts. UI-friendly descriptions live here so the call site can render
/// them directly.
enum ContactConversationStarterError: LocalizedError {
    case noContactsSelected
    case creationFailed
    case stateMachine(ConversationStateMachineError)
    case inviteJoinFailed(InviteJoinError)
    case underlying(Error)

    var errorDescription: String? {
        switch self {
        case .noContactsSelected:
            return "Pick at least one contact to start a conversation."
        case .creationFailed:
            return "We couldn't start that conversation. Please try again."
        case .stateMachine(let err):
            return err.localizedDescription
        case .inviteJoinFailed(let payload):
            return payload.userFacingMessage
        case .underlying(let err):
            return err.localizedDescription
        }
    }
}

/// Drives the create-then-add-members flow used by the contacts picker. The
/// existing state machine creates a draft and transitions to `.ready` with a
/// real conversationId; once ready, the chosen contacts are added via the
/// metadata writer's existing `addMembers` path.
@Observable
@MainActor
final class ContactConversationStarter {
    private(set) var isStarting: Bool = false
    private(set) var lastError: ContactConversationStarterError?

    private let session: any SessionManagerProtocol

    init(session: any SessionManagerProtocol) {
        self.session = session
    }

    /// Starts a new conversation with the given inboxIds. Returns the real
    /// conversation id on success. The conversation row will be present in
    /// the local feed; callers may listen for
    /// `Notification.Name.contactsRequestedNewConversation` to navigate the
    /// user into it from the conversations list.
    @discardableResult
    func start(with inboxIds: [String]) async throws -> String {
        guard !inboxIds.isEmpty else {
            throw ContactConversationStarterError.noContactsSelected
        }
        isStarting = true
        defer { isStarting = false }

        do {
            let conversationId = try await performStart(with: inboxIds)
            broadcastConversationCreated(conversationId)
            lastError = nil
            return conversationId
        } catch let mappedError as ContactConversationStarterError {
            lastError = mappedError
            throw mappedError
        } catch let stateMachineError as ConversationStateMachineError {
            let mapped: ContactConversationStarterError = .stateMachine(stateMachineError)
            lastError = mapped
            throw mapped
        } catch {
            let mapped: ContactConversationStarterError = .underlying(error)
            lastError = mapped
            throw mapped
        }
    }

    func clearError() {
        lastError = nil
    }

    // MARK: - Pipeline

    private func performStart(with inboxIds: [String]) async throws -> String {
        let prepared = await session.prepareNewConversation()
        let messagingService = prepared.service
        let stateManager: any ConversationStateManagerProtocol
        if let existingId = prepared.conversationId {
            stateManager = messagingService.conversationStateManager(for: existingId)
        } else {
            stateManager = messagingService.conversationStateManager()
        }

        // If the state machine is already in `.ready`, skip the create call —
        // we likely got handed back an in-progress draft.
        let alreadyReady = Self.readyResult(in: stateManager.currentState)
        let conversationId: String
        if let alreadyReady {
            conversationId = alreadyReady.conversationId
        } else {
            let creationTask = Task<Void, Error> {
                try await stateManager.createConversation()
            }
            do {
                conversationId = try await Self.awaitReadyState(stateManager: stateManager).conversationId
                _ = try? await creationTask.value
            } catch {
                creationTask.cancel()
                throw error
            }
        }

        let metadataWriter = messagingService.conversationMetadataWriter()
        try await metadataWriter.addMembers(inboxIds, to: conversationId)
        return conversationId
    }

    private func broadcastConversationCreated(_ conversationId: String) {
        NotificationCenter.default.post(
            name: .contactsRequestedNewConversation,
            object: nil,
            userInfo: ["conversationId": conversationId]
        )
    }

    // MARK: - State observation

    private static func readyResult(in state: ConversationStateMachine.State) -> ConversationReadyResult? {
        if case .ready(let result) = state {
            return result
        }
        return nil
    }

    private static func awaitReadyState(
        stateManager: any ConversationStateManagerProtocol
    ) async throws -> ConversationReadyResult {
        if let immediate = readyResult(in: stateManager.currentState) {
            return immediate
        }
        for await state in stateManager.stateSequence {
            switch state {
            case .ready(let result):
                return result
            case .error(let stateError):
                throw stateError
            case .joinFailed(_, let joinPayload):
                // `InviteJoinError` is a payload struct, not a Swift error.
                // The contact-driven create path shouldn't reach this case
                // (we're creating, not joining), but if the state machine
                // reports it, surface a typed error with the join payload's
                // user-facing message.
                throw ContactConversationStarterError.inviteJoinFailed(joinPayload)
            default:
                continue
            }
        }
        throw ContactConversationStarterError.creationFailed
    }
}

extension Notification.Name {
    /// Posted by `ContactConversationStarter` when a new conversation has
    /// been created from contacts and is ready to be opened. UserInfo
    /// contains `conversationId`. Listeners on the conversations list can
    /// use this to navigate the user into the new conversation.
    static let contactsRequestedNewConversation: Notification.Name = Notification.Name(
        "ContactsRequestedNewConversation"
    )

    /// Posted by surfaces inside an active chat (e.g. the "Add from Contacts"
    /// row in `NewConvoIdentityView`'s invite-members menu) to ask the
    /// containing `ConversationView` to present its contacts picker. Avoids
    /// plumbing a callback through ~9 layers of Messages / cell-factory /
    /// representable scaffolding for a single menu row. Carries no userInfo;
    /// the receiver already has the conversation context.
    static let requestAddFromContactsInCurrentConversation: Notification.Name = Notification.Name(
        "RequestAddFromContactsInCurrentConversation"
    )
}
