import ConvosConnections
import Foundation

public protocol ConnectionEventWriterProtocol: Sendable {
    func sendGranted(
        providerId: String,
        capability: ConnectionCapability?,
        grantedToInboxId: String?,
        in conversationId: String
    ) async throws
    func sendRevoked(
        providerId: String,
        capability: ConnectionCapability?,
        grantedToInboxId: String?,
        in conversationId: String
    ) async throws
}

public extension ConnectionEventWriterProtocol {
    func sendGranted(providerId: String, in conversationId: String) async throws {
        try await sendGranted(providerId: providerId, capability: nil, grantedToInboxId: nil, in: conversationId)
    }

    func sendRevoked(providerId: String, in conversationId: String) async throws {
        try await sendRevoked(providerId: providerId, capability: nil, grantedToInboxId: nil, in: conversationId)
    }
}

public enum ConnectionEventWriterError: Error, LocalizedError {
    case conversationNotFound(conversationId: String)

    public var errorDescription: String? {
        switch self {
        case .conversationNotFound(let id):
            return "Conversation not found: \(id)"
        }
    }
}

/// The raw single-conversation send underneath the writer protocol. Split out
/// so `ConnectionEventRouter` can fan a fully-formed event (including the
/// `notice` copy) into a specific conversation without re-deriving it from the
/// protocol's granted/revoked parameters.
protocol ConnectionEventSending: Sendable {
    func send(_ event: ConnectionEvent, in conversationId: String) async throws
}

final class ConnectionEventWriter: ConnectionEventWriterProtocol, ConnectionEventSending, Sendable {
    private let sessionStateManager: any SessionStateManagerProtocol

    init(sessionStateManager: any SessionStateManagerProtocol) {
        self.sessionStateManager = sessionStateManager
    }

    func sendGranted(
        providerId: String,
        capability: ConnectionCapability?,
        grantedToInboxId: String?,
        in conversationId: String
    ) async throws {
        try await send(
            ConnectionEvent(
                providerId: providerId,
                action: .granted,
                capability: capability,
                grantedToInboxId: grantedToInboxId
            ),
            in: conversationId
        )
    }

    func sendRevoked(
        providerId: String,
        capability: ConnectionCapability?,
        grantedToInboxId: String?,
        in conversationId: String
    ) async throws {
        try await send(
            ConnectionEvent(
                providerId: providerId,
                action: .revoked,
                capability: capability,
                grantedToInboxId: grantedToInboxId
            ),
            in: conversationId
        )
    }

    func send(_ event: ConnectionEvent, in conversationId: String) async throws {
        let inboxReady = try await sessionStateManager.waitForInboxReadyResult()
        let client = inboxReady.client

        guard let conversation = try await client.conversation(with: conversationId) else {
            throw ConnectionEventWriterError.conversationNotFound(conversationId: conversationId)
        }

        let encoded = try ConnectionEventCodec().encode(content: event)
        try await conversation.send(encodedContent: encoded)
    }
}
