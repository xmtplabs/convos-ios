import Foundation

public protocol CapabilityRequestResultWriterProtocol: Sendable {
    func sendResult(_ result: CapabilityRequestResult, in conversationId: String) async throws
}

public enum CapabilityRequestResultWriterError: Error, LocalizedError {
    case conversationNotFound(conversationId: String)

    public var errorDescription: String? {
        switch self {
        case .conversationNotFound(let id):
            return "Conversation not found: \(id)"
        }
    }
}

final class CapabilityRequestResultWriter: CapabilityRequestResultWriterProtocol, Sendable {
    private let sessionStateManager: any SessionStateManagerProtocol

    init(sessionStateManager: any SessionStateManagerProtocol) {
        self.sessionStateManager = sessionStateManager
    }

    func sendResult(_ result: CapabilityRequestResult, in conversationId: String) async throws {
        let inboxReady = try await sessionStateManager.waitForInboxReadyResult()
        let client = inboxReady.client

        guard let conversation = try await client.conversation(with: conversationId) else {
            throw CapabilityRequestResultWriterError.conversationNotFound(conversationId: conversationId)
        }

        let encoded = try CapabilityRequestResultCodec().encode(content: result)
        try await conversation.send(encodedContent: encoded)

        let providers = result.providers.map(\.rawValue).joined(separator: ",")
        Log.info("[CapabilityResolution] sent capability_request_result requestId=\(result.requestId) status=\(result.status.rawValue) providers=\(providers)")
    }
}
