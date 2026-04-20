import ConvosInvites
import Foundation
import GRDB
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
    private let databaseWriter: any DatabaseWriter

    init(identityStore: any KeychainIdentityStoreProtocol,
         databaseWriter: any DatabaseWriter,
         tagStorage: any InviteTagStorageProtocol = ProtobufInviteTagStorage()) {
        self.databaseWriter = databaseWriter
        self.coordinator = InviteCoordinator(
            privateKeyProvider: { inboxId in
                guard let identity = try await identityStore.load(), identity.inboxId == inboxId else {
                    throw KeychainIdentityStoreError.identityNotFound("No singleton identity matching inbox \(inboxId)")
                }
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
        await persistJoinerProfile(result)
        await sendProfileSnapshotAfterJoin(conversationId: result.conversationId, client: client)
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
        var results: [JoinRequestResult] = []
        for joinResult in await coordinator.processJoinRequests(since: since, client: InviteClientProviderAdapter(client)) {
            logAccepted(joinResult)
            await persistJoinerProfile(joinResult)
            results.append(JoinRequestResult(
                conversationId: joinResult.conversationId,
                conversationName: joinResult.conversationName,
                joinerInboxId: joinResult.joinerInboxId,
                profile: joinResult.profile,
                metadata: joinResult.metadata
            ))
        }
        return results
    }

    func hasOutgoingJoinRequest(
        for conversation: XMTPiOS.Group,
        client: AnyClientProvider
    ) async throws -> Bool {
        try await coordinator.hasOutgoingJoinRequest(for: conversation, client: InviteClientProviderAdapter(client))
    }

    private func persistJoinerProfile(_ result: JoinResult) async {
        let profile = result.profile
        let metadata = result.metadata
        guard profile?.name != nil || profile?.imageURL != nil || profile?.memberKind != nil || metadata != nil else { return }

        let baseMemberKind: DBMemberKind? = profile?.memberKind == "agent" ? .agent : nil
        let profileMetadata: ProfileMetadata? = metadata.flatMap { dict in
            let mapped = dict.compactMapValues { ProfileMetadataValue.string($0) }
            return mapped.isEmpty ? nil : mapped
        }

        let memberKind: DBMemberKind?
        if baseMemberKind != nil, let profileMetadata {
            let tempProfile = Profile(
                inboxId: result.joinerInboxId,
                conversationId: result.conversationId,
                name: profile?.name,
                avatar: profile?.imageURL,
                isAgent: true,
                metadata: profileMetadata
            )
            let verification = tempProfile.verifyCachedAgentAttestation()
            memberKind = DBMemberKind.from(agentVerification: verification)
        } else {
            memberKind = baseMemberKind
        }

        do {
            try await databaseWriter.write { db in
                let member = DBMember(inboxId: result.joinerInboxId)
                try member.save(db)

                let dbProfile = DBMemberProfile(
                    conversationId: result.conversationId,
                    inboxId: result.joinerInboxId,
                    name: profile?.name,
                    avatar: profile?.imageURL,
                    memberKind: memberKind,
                    metadata: profileMetadata
                )
                try dbProfile.save(db)

                if dbProfile.agentVerification.isConvosAssistant,
                   let conversation = try DBConversation.fetchOne(db, id: result.conversationId),
                   !conversation.hasHadVerifiedAssistant {
                    try conversation.with(hasHadVerifiedAssistant: true).save(db)
                }
            }
            Log.debug("Persisted join request profile for \(result.joinerInboxId) in \(result.conversationId)")
        } catch {
            Log.warning("Failed to persist join request profile: \(error.localizedDescription)")
        }
    }

    private func logAccepted(_ result: JoinResult) {
        Log.info("Successfully added \(result.joinerInboxId) to conversation \(result.conversationId)")
        QAEvent.emit(.invite, "member_accepted", [
            "conversation": result.conversationId,
            "member": result.joinerInboxId,
        ])
    }

    private func sendProfileSnapshotAfterJoin(conversationId: String, client: AnyClientProvider) async {
        do {
            guard let conversation = try await client.conversationsProvider.findConversation(
                conversationId: conversationId
            ), case .group(let group) = conversation else {
                return
            }
            let allMemberInboxIds = try await group.members.map(\.inboxId)
            try await ProfileSnapshotBuilder.sendSnapshot(
                group: group,
                memberInboxIds: allMemberInboxIds
            )
            Log.debug("Sent ProfileSnapshot after join request for \(conversationId)")
        } catch {
            Log.warning("Failed to send ProfileSnapshot after join: \(error.localizedDescription)")
        }
    }
}
