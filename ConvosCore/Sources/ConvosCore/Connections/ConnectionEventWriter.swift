import ConvosConnections
import Foundation

public protocol ConnectionEventWriterProtocol: Sendable {
    func sendGranted(providerId: String, in conversationId: String) async throws
    func sendRevoked(providerId: String, in conversationId: String) async throws
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

final class ConnectionEventWriter: ConnectionEventWriterProtocol, Sendable {
    private let sessionStateManager: any SessionStateManagerProtocol

    init(sessionStateManager: any SessionStateManagerProtocol) {
        self.sessionStateManager = sessionStateManager
    }

    func sendGranted(providerId: String, in conversationId: String) async throws {
        try await sendEvent(.granted, providerId: providerId, in: conversationId)
    }

    func sendRevoked(providerId: String, in conversationId: String) async throws {
        try await sendEvent(.revoked, providerId: providerId, in: conversationId)
    }

    private func sendEvent(_ action: ConnectionEvent.Action, providerId: String, in conversationId: String) async throws {
        let inboxReady = try await sessionStateManager.waitForInboxReadyResult()
        let client = inboxReady.client

        guard let conversation = try await client.conversation(with: conversationId) else {
            throw ConnectionEventWriterError.conversationNotFound(conversationId: conversationId)
        }

        let encoded = try ConnectionEventCodec().encode(content: .init(providerId: providerId, action: action))
        try await conversation.send(encodedContent: encoded)
    }
}
