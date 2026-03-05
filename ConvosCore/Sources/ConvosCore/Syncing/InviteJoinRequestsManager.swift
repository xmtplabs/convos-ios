import ConvosInvites
import Foundation
@preconcurrency import XMTPiOS

public struct JoinRequestResult: Sendable {
    public let conversationId: String
    public let conversationName: String?
    public let joinerInboxId: String
    public let profile: JoinRequestProfile?
    public let metadata: [String: String]?
}

protocol InviteJoinRequestsManagerProtocol: Sendable {
    func processJoinRequest(
        message: XMTPiOS.DecodedMessage,
        client: AnyClientProvider
    ) async -> JoinRequestResult?
    func processJoinRequests(
        since: Date?,
        client: AnyClientProvider
    ) async -> [JoinRequestResult]
    func hasOutgoingJoinRequest(
        for conversation: XMTPiOS.Group,
        client: AnyClientProvider
    ) async throws -> Bool
}

/// Bridges ConvosCore callers to `InviteCoordinator`, adding logging and QA events.
final class InviteJoinRequestsManager: InviteJoinRequestsManagerProtocol, Sendable {
    private let coordinator: InviteCoordinator

    init(identityStore: any KeychainIdentityStoreProtocol,
         tagStorage: any InviteTagStorageProtocol = ProtobufInviteTagStorage()) {
        self.coordinator = InviteCoordinator(
            privateKeyProvider: { inboxId in
                let identity = try await identityStore.identity(for: inboxId)
                return identity.keys.privateKey.secp256K1.bytes
            },
            tagStorage: tagStorage
        )
    }

    func processJoinRequest(
        message: XMTPiOS.DecodedMessage,
        client: AnyClientProvider
    ) async -> JoinRequestResult? {
        guard let result = await coordinator.processMessage(message, client: InviteClientProviderAdapter(client)) else {
            return nil
        }
        logAccepted(result)
        return JoinRequestResult(
            conversationId: result.conversationId,
            conversationName: result.conversationName,
            joinerInboxId: result.joinerInboxId,
            profile: result.profile,
            metadata: result.metadata
        )
    }

    func processJoinRequests(
        since: Date?,
        client: AnyClientProvider
    ) async -> [JoinRequestResult] {
        await coordinator.processJoinRequests(since: since, client: InviteClientProviderAdapter(client)).map {
            logAccepted($0)
            return JoinRequestResult(
                conversationId: $0.conversationId,
                conversationName: $0.conversationName,
                joinerInboxId: $0.joinerInboxId,
                profile: $0.profile,
                metadata: $0.metadata
            )
        }
    }

    func hasOutgoingJoinRequest(
        for conversation: XMTPiOS.Group,
        client: AnyClientProvider
    ) async throws -> Bool {
        try await coordinator.hasOutgoingJoinRequest(for: conversation, client: InviteClientProviderAdapter(client))
    }

    private func logAccepted(_ result: JoinResult) {
        Log.info("Successfully added \(result.joinerInboxId) to conversation \(result.conversationId)")
        QAEvent.emit(.invite, "member_accepted", [
            "conversation": result.conversationId,
            "member": result.joinerInboxId,
        ])
    }
}
