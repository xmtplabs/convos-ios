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

/// Core-local projection of `JoinRequestDMOutcome` after applying ConvosCore
/// side effects, including profile persistence and post-join profile snapshots.
///
/// Mirrors the upstream cases. See `JoinRequestDMOutcome` for the full
/// per-case rationale, including why `benignFailure` keeps the DM
/// subscribed (transient/local errors should not block legitimate retries
/// from the same joiner).
enum InviteJoinRequestOutcome: Sendable {
    case accepted(JoinRequestResult, dmConversationId: String)
    case benignFailure(dmConversationId: String, senderInboxId: String?, error: JoinRequestError)
    case malicious(dmConversationId: String, senderInboxId: String, error: JoinRequestError)
    case alreadyMember(dmConversationId: String, joinerInboxId: String)
    case noJoinRequest

    var result: JoinRequestResult? {
        guard case .accepted(let result, dmConversationId: _) = self else { return nil }
        return result
    }

    var dmConversationId: String? {
        switch self {
        case .accepted(_, dmConversationId: let dmConversationId):
            return dmConversationId
        case .benignFailure(let dmConversationId, _, _):
            return dmConversationId
        case .malicious(let dmConversationId, _, _):
            return dmConversationId
        case .alreadyMember(let dmConversationId, _):
            return dmConversationId
        case .noJoinRequest:
            return nil
        }
    }

    var shouldKeepDMSubscribed: Bool {
        switch self {
        case .accepted, .benignFailure, .alreadyMember:
            return true
        case .malicious, .noJoinRequest:
            return false
        }
    }
}

protocol InviteJoinRequestsManagerProtocol: Sendable {
    func processJoinRequest(
        message: XMTPiOS.DecodedMessage,
        client: AnyClientProvider
    ) async -> JoinRequestResult?
    func processJoinRequestOutcome(
        message: XMTPiOS.DecodedMessage,
        client: AnyClientProvider
    ) async -> InviteJoinRequestOutcome
    func processJoinRequests(
        since: Date?,
        client: AnyClientProvider
    ) async -> [JoinRequestResult]
    func processJoinRequestOutcomes(
        since: Date?,
        client: AnyClientProvider
    ) async -> [InviteJoinRequestOutcome]
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
         tagStorage: any InviteTagStorageProtocol = ProtobufInviteTagStorage(),
         handledRequestStore: (any HandledJoinRequestStoreProtocol)? = nil) {
        self.databaseWriter = databaseWriter
        self.coordinator = InviteCoordinator(
            privateKeyProvider: { inboxId in
                guard let identity = try await identityStore.load(), identity.inboxId == inboxId else {
                    throw KeychainIdentityStoreError.identityNotFound("No singleton identity matching inbox \(inboxId)")
                }
                return identity.keys.privateKey.secp256K1.bytes
            },
            tagStorage: tagStorage,
            // The persistent ledger is what keeps an already-honored join
            // request inert across passes and processes; every production
            // caller funnels through this default.
            handledRequestStore: handledRequestStore ?? DatabaseHandledJoinRequestStore(databaseWriter: databaseWriter)
        )
    }

    func processJoinRequest(
        message: XMTPiOS.DecodedMessage,
        client: AnyClientProvider
    ) async -> JoinRequestResult? {
        let outcome = await processJoinRequestOutcome(message: message, client: client)
        return outcome.result
    }

    func processJoinRequestOutcome(
        message: XMTPiOS.DecodedMessage,
        client: AnyClientProvider
    ) async -> InviteJoinRequestOutcome {
        let outcome = await coordinator.processMessageOutcome(
            message,
            client: InviteClientProviderAdapter(client)
        )
        return await mapOutcome(outcome, client: client)
    }

    func processJoinRequests(
        since: Date?,
        client: AnyClientProvider
    ) async -> [JoinRequestResult] {
        let outcomes = await processJoinRequestOutcomes(since: since, client: client)
        return outcomes.compactMap(\.result)
    }

    /// Eventual-consistency note: between the moment the coordinator
    /// snapshots the DM list and the moment the caller subscribes /
    /// unsubscribes from push topics for those outcomes, a new join
    /// request can land in another DM. That request is missed by the
    /// current pass, so the device may briefly hold a stale push
    /// subscription set. The next reconcile (after sync, resume, or
    /// `requestDiscovery` — see `SyncingManager`) heals it. We accept
    /// the lag because serializing the whole pipeline would require an
    /// app-wide lock around DM message delivery for marginal benefit.
    func processJoinRequestOutcomes(
        since: Date?,
        client: AnyClientProvider
    ) async -> [InviteJoinRequestOutcome] {
        let effectiveSince = Self.effectiveCatchUpSince(since: since, now: Date())
        let outcomes = await coordinator.processJoinRequestOutcomes(
            since: effectiveSince,
            client: InviteClientProviderAdapter(client)
        )
        var mapped: [InviteJoinRequestOutcome] = []
        for outcome in outcomes {
            mapped.append(await mapOutcome(outcome, client: client))
        }
        return mapped
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
                // Note: `Date()` here rather than the message's `sentAtNs`
                // because `JoinResult` doesn't carry the original timestamp.
                // Tracked as a follow-up — see the contacts MVP plan.
                try ContactsWriter.saveMemberProfileAndMirrorToContactInTransaction(db: db, profile: dbProfile, receivedAt: Date())

                if dbProfile.agentVerification.isConvosAgent,
                   let conversation = try DBConversation.fetchOne(db, id: result.conversationId),
                   !conversation.hasHadVerifiedAgent {
                    try conversation.with(hasHadVerifiedAgent: true).save(db)
                }
            }
            Log.debug("Persisted join request profile for \(result.joinerInboxId) in \(result.conversationId)")
        } catch {
            Log.warning("Failed to persist join request profile: \(error.localizedDescription)")
        }
    }

    private func mapOutcome(
        _ outcome: JoinRequestDMOutcome,
        client: AnyClientProvider
    ) async -> InviteJoinRequestOutcome {
        switch outcome {
        case let .accepted(result, dmConversationId: dmConversationId):
            logAccepted(result)
            await persistJoinerProfile(result)
            await sendProfileSnapshotAfterJoin(conversationId: result.conversationId, client: client)
            await sendConversationSnapshotAfterJoin(conversationId: result.conversationId, client: client)
            return .accepted(
                JoinRequestResult(
                    conversationId: result.conversationId,
                    conversationName: result.conversationName,
                    joinerInboxId: result.joinerInboxId,
                    profile: result.profile,
                    metadata: result.metadata
                ),
                dmConversationId: dmConversationId
            )
        case let .benignFailure(dmConversationId, senderInboxId, error):
            Log.info("Join request failed without blocking DM \(dmConversationId): \(error)")
            return .benignFailure(
                dmConversationId: dmConversationId,
                senderInboxId: senderInboxId,
                error: error
            )
        case let .malicious(dmConversationId, senderInboxId, error):
            Log.warning("Join request marked malicious for DM \(dmConversationId), sender \(senderInboxId): \(error)")
            return .malicious(
                dmConversationId: dmConversationId,
                senderInboxId: senderInboxId,
                error: error
            )
        case let .alreadyMember(dmConversationId, joinerInboxId):
            Log.debug("Join request for \(joinerInboxId) already handled by another pass (DM \(dmConversationId))")
            return .alreadyMember(
                dmConversationId: dmConversationId,
                joinerInboxId: joinerInboxId
            )
        case .noJoinRequest:
            return .noJoinRequest
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
            Log.info("Sent ProfileSnapshot after join request for \(conversationId)")
        } catch {
            Log.warning("Failed to send ProfileSnapshot after join: \(error.localizedDescription)")
        }
    }

    /// Broadcasts the latest convo-level state to the group right after a new
    /// member is admitted. Mirrors `sendProfileSnapshotAfterJoin` but for
    /// silent codecs (focus mode today, room for more later) — XMTP streams
    /// are forward-only, so a member who joins after a `FocusModeControl`
    /// has already been sent would never see it without this catch-up.
    private func sendConversationSnapshotAfterJoin(conversationId: String, client: AnyClientProvider) async {
        do {
            guard let conversation = try await client.conversationsProvider.findConversation(
                conversationId: conversationId
            ), case .group(let group) = conversation else {
                return
            }
            let focusBlock = try? await loadLatestFocusSession(conversationId: conversationId)
            let snapshot = ConversationSnapshot(focusSession: focusBlock)
            let codec = ConversationSnapshotCodec()
            let encoded = try codec.encode(content: snapshot)
            _ = try await group.send(encodedContent: encoded)
            Log.info("Sent ConversationSnapshot after join request for \(conversationId) (focusSession: \(focusBlock != nil))")
        } catch {
            Log.warning("Failed to send ConversationSnapshot after join: \(error.localizedDescription)")
        }
    }

    private func loadLatestFocusSession(conversationId: String) async throws -> ConversationSnapshot.FocusSession? {
        try await databaseWriter.read { db in
            guard let session = try DBFocusSession
                .filter(Column("conversationId") == conversationId)
                .order(Column("startedAt").desc)
                .fetchOne(db) else {
                return nil
            }
            let state: FocusModeControl.State
            switch session.state {
            case .started: state = .start
            case .stopped: state = .stop
            }
            return ConversationSnapshot.FocusSession(
                sessionId: session.sessionId,
                state: state,
                focusedInboxId: session.focusedInboxId
            )
        }
    }

    /// A nil or very old cursor (fresh install, restore, long-dormant
    /// device) would revalidate every historical join request in every
    /// DM and reply with stale invite_join_error messages to joiners
    /// whose requests died long ago. Joiners give up within minutes, so
    /// bound the sweep to a recent window.
    static func effectiveCatchUpSince(since: Date?, now: Date) -> Date {
        let oldestUsefulRequestDate = now.addingTimeInterval(-Constant.maxCatchUpWindow)
        return max(since ?? .distantPast, oldestUsefulRequestDate)
    }

    private enum Constant {
        /// Oldest join request a catch-up pass will still act on. Joining
        /// clients time out within minutes, so anything older only produces
        /// noise (and stale error replies) if revalidated.
        static let maxCatchUpWindow: TimeInterval = 24 * 60 * 60
    }
}
