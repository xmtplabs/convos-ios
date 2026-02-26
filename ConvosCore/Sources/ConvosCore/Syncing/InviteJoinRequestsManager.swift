import ConvosInvites
import Foundation
@preconcurrency import XMTPiOS

public struct JoinRequestResult: Sendable {
    public let conversationId: String
    public let conversationName: String?
    public let joinerInboxId: String
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

/// Thin bridge that creates an `InviteCoordinator` per call, adapting
/// ConvosCore's `AnyClientProvider` to the package's `InviteClientProvider`.
///
/// All join request logic lives in ConvosInvites' `InviteCoordinator`;
/// this type adds Convos-specific logging and QA events via the delegate.
final class InviteJoinRequestsManager: InviteJoinRequestsManagerProtocol, @unchecked Sendable {
    private let identityStore: any KeychainIdentityStoreProtocol
    private let tagStorage: any InviteTagStorageProtocol

    init(
        identityStore: any KeychainIdentityStoreProtocol,
        tagStorage: any InviteTagStorageProtocol = ProtobufInviteTagStorage()
    ) {
        self.identityStore = identityStore
        self.tagStorage = tagStorage
    }

    func processJoinRequest(
        message: XMTPiOS.DecodedMessage,
        client: AnyClientProvider
    ) async -> JoinRequestResult? {
        let coordinator = makeCoordinator(for: client)
        guard let result = await coordinator.processMessage(message) else {
            return nil
        }
        Log.info("Successfully added \(result.joinerInboxId) to conversation \(result.conversationId)")
        QAEvent.emit(.invite, "member_accepted", [
            "conversation": result.conversationId,
            "member": result.joinerInboxId,
        ])
        return JoinRequestResult(
            conversationId: result.conversationId,
            conversationName: result.conversationName,
            joinerInboxId: result.joinerInboxId
        )
    }

    func processJoinRequests(
        since: Date?,
        client: AnyClientProvider
    ) async -> [JoinRequestResult] {
        let coordinator = makeCoordinator(for: client)
        let results = await coordinator.processJoinRequests(since: since)
        return results.map {
            Log.info("Successfully added \($0.joinerInboxId) to conversation \($0.conversationId)")
            QAEvent.emit(.invite, "member_accepted", [
                "conversation": $0.conversationId,
                "member": $0.joinerInboxId,
            ])
            return JoinRequestResult(
                conversationId: $0.conversationId,
                conversationName: $0.conversationName,
                joinerInboxId: $0.joinerInboxId
            )
        }
    }

    func hasOutgoingJoinRequest(
        for conversation: XMTPiOS.Group,
        client: AnyClientProvider
    ) async throws -> Bool {
        let coordinator = makeCoordinator(for: client)
        return try await coordinator.hasOutgoingJoinRequest(for: conversation)
    }

    private func makeCoordinator(for client: AnyClientProvider) -> InviteCoordinator {
        let identityStore = self.identityStore
        return InviteCoordinator(
            client: InviteClientProviderAdapter(client),
            privateKeyProvider: { inboxId in
                let identity = try await identityStore.identity(for: inboxId)
                return identity.keys.privateKey.secp256K1.bytes
            },
            tagStorage: tagStorage
        )
    }
}
