import ConvosInvites
import ConvosMessagingProtocols
import ConvosProfiles
import Foundation
import GRDB
// FIXME(stage4): `@preconcurrency import XMTPiOS` remains because the
// DM back-channel for the invite flow (audit open question #4) passes
// `XMTPiOS.DecodedMessage` and `XMTPiOS.Group` through to
// `ConvosInvites.InviteCoordinator` / `InviteClientProviderAdapter`.
// `ConvosInvites` is a sibling SwiftPM package that ConvosCore depends
// on, so it cannot depend on ConvosCore's `Messaging*` protocols
// without a circular import (per directive for Stage 4e). Once
// `ConvosInvites` migrates to a package-local signer / group protocol
// or promotes the `Messaging*` types out of ConvosCore, this file can
// migrate in lockstep.
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
        client: any MessagingClient
    ) async -> JoinRequestResult?
    func processJoinRequests(
        since: Date?,
        client: any MessagingClient
    ) async -> [JoinRequestResult]
    func hasOutgoingJoinRequest(
        for conversation: XMTPiOS.Group,
        client: any MessagingClient
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
                let identity = try await identityStore.identity(for: inboxId)
                return identity.keys.privateKey.secp256K1.bytes
            },
            tagStorage: tagStorage
        )
    }

    func processJoinRequest(
        message: XMTPiOS.DecodedMessage,
        client: any MessagingClient
    ) async -> JoinRequestResult? {
        // Stage 6f Step 8: `InviteCoordinator.processMessage` is now
        // typed against the abstraction-side `MessagingMessage`. Wrap
        // the XMTPiOS-side `DecodedMessage` once at this boundary so
        // ConvosInvites no longer needs an XMTPiOS dependency on its
        // public coordinator surface.
        guard let messagingMessage = try? MessagingMessage(message) else {
            return nil
        }
        guard let result = await coordinator.processMessage(messagingMessage, client: InviteClientProviderAdapter(client)) else {
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
        client: any MessagingClient
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
        client: any MessagingClient
    ) async throws -> Bool {
        // Stage 6f Step 7: `InviteCoordinator.hasOutgoingJoinRequest`
        // takes `any MessagingGroup` after the protocol-surface lift.
        // StreamProcessor still calls in with a raw `XMTPiOS.Group`; we
        // wrap it through `XMTPiOSMessagingGroup` here so the legacy
        // call site continues to work. StreamProcessor's own migration
        // is deferred (Gap 2 territory).
        let messagingGroup = XMTPiOSMessagingGroup(xmtpGroup: conversation)
        return try await coordinator.hasOutgoingJoinRequest(
            for: messagingGroup,
            client: InviteClientProviderAdapter(client)
        )
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

    private func sendProfileSnapshotAfterJoin(conversationId: String, client: any MessagingClient) async {
        do {
            // Stage 6e Phase B-2: route lookup through MessagingClient.
            // ProfileSnapshotBuilder still operates on XMTPiOS.Group
            // (XIP-payload + writer surface is XMTPiOS-typed); reach the
            // underlying handle via the XMTPiOSMessagingGroup adapter.
            guard let messagingGroup = try await client.messagingGroup(with: conversationId) else {
                return
            }
            guard let xmtpAdapter = messagingGroup as? XMTPiOSMessagingGroup else {
                Log.warning("sendProfileSnapshotAfterJoin: non-XMTPiOS group adapter; skipping snapshot")
                return
            }
            let group = xmtpAdapter.underlyingXMTPiOSGroup
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
