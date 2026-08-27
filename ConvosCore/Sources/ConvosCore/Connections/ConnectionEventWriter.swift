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

    /// Sends one granted event for every cloud provider and agent pair. Every
    /// invocation performs fresh sends so a caller can safely retry after a
    /// partial failure.
    func sendCloudGrantedEvents(
        providerIds: [ProviderID],
        capability: ConnectionCapability?,
        grantedToInboxIds: [String],
        in conversationId: String
    ) async throws {
        var firstError: (any Error)?
        for grantedToInboxId in grantedToInboxIds {
            for providerId in providerIds where providerId.cloudServiceId != nil {
                do {
                    try await sendGranted(
                        providerId: providerId.rawValue,
                        capability: capability,
                        grantedToInboxId: grantedToInboxId,
                        in: conversationId
                    )
                } catch {
                    firstError = firstError ?? error
                }
            }
        }
        if let firstError {
            throw firstError
        }
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

final class ConnectionEventWriter: ConnectionEventWriterProtocol, Sendable {
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
        try await sendEvent(
            .granted,
            providerId: providerId,
            capability: capability,
            grantedToInboxId: grantedToInboxId,
            in: conversationId
        )
    }

    func sendRevoked(
        providerId: String,
        capability: ConnectionCapability?,
        grantedToInboxId: String?,
        in conversationId: String
    ) async throws {
        try await sendEvent(
            .revoked,
            providerId: providerId,
            capability: capability,
            grantedToInboxId: grantedToInboxId,
            in: conversationId
        )
    }

    private func sendEvent(
        _ action: ConnectionEvent.Action,
        providerId: String,
        capability: ConnectionCapability?,
        grantedToInboxId: String?,
        in conversationId: String
    ) async throws {
        let inboxReady = try await sessionStateManager.waitForInboxReadyResult()
        let client = inboxReady.client

        guard let conversation = try await client.conversation(with: conversationId) else {
            throw ConnectionEventWriterError.conversationNotFound(conversationId: conversationId)
        }

        let event = ConnectionEvent(
            providerId: providerId,
            action: action,
            capability: capability,
            grantedToInboxId: grantedToInboxId
        )
        let encoded = try ConnectionEventCodec().encode(content: event)
        try await conversation.send(encodedContent: encoded)
    }
}
