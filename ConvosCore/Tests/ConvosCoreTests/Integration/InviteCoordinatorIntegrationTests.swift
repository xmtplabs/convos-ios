@testable import ConvosCore
import ConvosInvites
import Foundation
import Testing
@preconcurrency import XMTPiOS

/// Integration tests for InviteCoordinator that exercise the full join-request
/// flow against a local XMTP node (`./dev/up`). Add new cases here when the
/// behavior depends on real DM/group state, MLS routing, or consent
/// transitions — anything a pure mock can't simulate.
@Suite("InviteCoordinator Integration Tests", .serialized)
struct InviteCoordinatorIntegrationTests {
    // Deterministic 32-byte secp256k1 key shared by every InviteCoordinator
    // instance in this suite, regardless of which XMTP inbox is asking.
    // The coordinator only uses it to sign / decrypt invite slugs; it does
    // not need to match the XMTP wallet identity for the test flow.
    private let creatorInviteKey: Data = Data((1...32).map { UInt8($0) })

    private func createClient() async throws -> Client {
        var keyBytes = [UInt8](repeating: 0, count: 32)
        _ = SecRandomCopyBytes(kSecRandomDefault, 32, &keyBytes)
        let dbKey = Data(keyBytes)
        let tmpDir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
        let options = ClientOptions(
            api: .init(env: .local, appVersion: "convos-tests/1.0.0"),
            codecs: [
                TextCodec(),
                JoinRequestCodec(),
                InviteJoinErrorCodec(),
            ],
            dbEncryptionKey: dbKey,
            dbDirectory: tmpDir.path
        )
        return try await Client.create(
            account: try PrivateKey.generate(),
            options: options
        )
    }

    private func makeCoordinator() -> InviteCoordinator {
        let key = creatorInviteKey
        return InviteCoordinator(privateKeyProvider: { _ in key })
    }

    /// Repro for the bug fixed in 686bd9fa: after a creator accepted the
    /// first join request through a DM, that DM's consent flipped to
    /// `.allowed`. A second join request landing in the *same* DM (e.g.
    /// the joiner using a new invite for a different group) was then
    /// silently dropped by the NSE because `processJoinRequestOutcomes`
    /// listed DMs with `consentStates: [.unknown]` and a `createdAfterNs`
    /// time window that never matched the now-old DM.
    @Test("Processes a second join request through a DM whose consent is already .allowed")
    func processesSecondJoinThroughAlreadyAllowedDm() async throws {
        let creatorClient = try await createClient()
        let joinerClient = try await createClient()
        defer {
            try? creatorClient.deleteLocalDatabase()
            try? joinerClient.deleteLocalDatabase()
        }
        let coordinator = makeCoordinator()

        let group1 = try await creatorClient.conversations.newGroup(with: [])
        try await group1.updateConsentState(state: .allowed)
        _ = try await coordinator.revokeInvites(for: group1)
        let invite1 = try await coordinator.createInvite(for: group1, client: creatorClient)

        _ = try await coordinator.sendJoinRequest(
            for: invite1.signedInvite,
            client: joinerClient
        )

        _ = try await creatorClient.conversations.syncAllConversations(consentStates: nil)
        let firstOutcomes = await coordinator.processJoinRequestOutcomes(
            since: nil,
            client: creatorClient
        )
        let firstAccepted = firstOutcomes.compactMap(\.joinResult)
        #expect(firstAccepted.contains { $0.conversationId == group1.id })

        // Mark the boundary between the two passes. After this point
        // anything new on the DM should still surface to the creator.
        let cutoff = Date()
        try await Task.sleep(nanoseconds: 100_000_000)

        let group2 = try await creatorClient.conversations.newGroup(with: [])
        try await group2.updateConsentState(state: .allowed)
        _ = try await coordinator.revokeInvites(for: group2)
        let invite2 = try await coordinator.createInvite(for: group2, client: creatorClient)

        _ = try await coordinator.sendJoinRequest(
            for: invite2.signedInvite,
            client: joinerClient
        )

        _ = try await creatorClient.conversations.syncAllConversations(consentStates: nil)
        let secondOutcomes = await coordinator.processJoinRequestOutcomes(
            since: cutoff,
            client: creatorClient
        )
        let secondAccepted = secondOutcomes.compactMap(\.joinResult)
        #expect(
            secondAccepted.contains { $0.conversationId == group2.id },
            "Second join request must be processed even though DM consent is .allowed"
        )

        // Sanity: the second pass should not double-emit the first join.
        #expect(!secondAccepted.contains { $0.conversationId == group1.id })
    }

    /// Plain-text slug messages are still join requests: builds that predate
    /// the typed joiner path (2.0.0 and earlier) send text only, so the
    /// creator must keep accepting them until the installed fleet is on
    /// typed-sending builds.
    @Test("Plain-text slug message joins the group")
    func plainTextSlugJoins() async throws {
        let creatorClient = try await createClient()
        let joinerClient = try await createClient()
        defer {
            try? creatorClient.deleteLocalDatabase()
            try? joinerClient.deleteLocalDatabase()
        }
        let coordinator = makeCoordinator()

        let group = try await creatorClient.conversations.newGroup(with: [])
        try await group.updateConsentState(state: .allowed)
        _ = try await coordinator.revokeInvites(for: group)
        let invite = try await coordinator.createInvite(for: group, client: creatorClient)

        // Send the slug as plain text, the pre-typed wire format.
        let dm = try await joinerClient.conversations.findOrCreateDm(with: creatorClient.inboxID)
        _ = try await dm.send(content: invite.slug)

        _ = try await creatorClient.conversations.syncAllConversations(consentStates: nil)
        let outcomes = await coordinator.processJoinRequestOutcomes(
            since: nil,
            client: creatorClient
        )

        #expect(outcomes.compactMap(\.joinResult).contains { $0.conversationId == group.id })

        let memberInboxIds = try await group.members.map(\.inboxId)
        #expect(memberInboxIds.contains(joinerClient.inboxID), "Text-slug joiner must be added to the group")
    }

    /// Herald sends a typed join_request plus a plain-text slug copy. A
    /// failing pair must produce exactly one invite_join_error (the
    /// per-attempt dedupe suppresses the second copy's reply) - this is the
    /// flood-regression guard for keeping text acceptance enabled.
    @Test("Typed plus text pair for a failing invite produces exactly one error")
    func typedAndTextPairProducesSingleError() async throws {
        let creatorClient = try await createClient()
        let joinerClient = try await createClient()
        defer {
            try? creatorClient.deleteLocalDatabase()
            try? joinerClient.deleteLocalDatabase()
        }
        let coordinator = makeCoordinator()

        let group = try await creatorClient.conversations.newGroup(with: [])
        try await group.updateConsentState(state: .allowed)
        _ = try await coordinator.revokeInvites(for: group)
        let invite = try await coordinator.createInvite(for: group, client: creatorClient)
        // Rotate the tag so the invite above is revoked and the join fails
        // down the error-sending path.
        _ = try await coordinator.revokeInvites(for: group)

        // sendJoinRequest sends the typed message; follow with the text
        // copy the way Herald does.
        let dm = try await coordinator.sendJoinRequest(for: invite.signedInvite, client: joinerClient)
        _ = try await dm.send(content: invite.slug)

        _ = try await creatorClient.conversations.syncAllConversations(consentStates: nil)
        _ = await coordinator.processJoinRequestOutcomes(since: nil, client: creatorClient)
        // Revalidate, as batch catch-up and the agent-join poll do.
        _ = await coordinator.processJoinRequestOutcomes(since: nil, client: creatorClient)

        let errorCount = try await joinErrorCount(inDmWith: joinerClient.inboxID, client: creatorClient)
        #expect(errorCount == 1, "A failing typed+text pair must produce exactly one error reply")
    }

    /// The error-reply dedupe: revalidating the same failed join request
    /// (stream, catch-up, and the agent-join poll all see the same message)
    /// sends exactly one invite_join_error - but a fresh retry by the joiner
    /// is a new attempt and gets a fresh reply.
    @Test("Failed join gets one error per attempt across repeated processing passes")
    func failedJoinErrorIsDedupedPerAttempt() async throws {
        let creatorClient = try await createClient()
        let joinerClient = try await createClient()
        defer {
            try? creatorClient.deleteLocalDatabase()
            try? joinerClient.deleteLocalDatabase()
        }
        let coordinator = makeCoordinator()

        let group = try await creatorClient.conversations.newGroup(with: [])
        try await group.updateConsentState(state: .allowed)
        _ = try await coordinator.revokeInvites(for: group)
        let invite = try await coordinator.createInvite(for: group, client: creatorClient)
        // Rotate the tag so the invite above is revoked and every join
        // attempt with it fails down the error-sending path.
        _ = try await coordinator.revokeInvites(for: group)

        _ = try await coordinator.sendJoinRequest(for: invite.signedInvite, client: joinerClient)

        _ = try await creatorClient.conversations.syncAllConversations(consentStates: nil)
        _ = await coordinator.processJoinRequestOutcomes(since: nil, client: creatorClient)
        var errorCount = try await joinErrorCount(inDmWith: joinerClient.inboxID, client: creatorClient)
        #expect(errorCount == 1, "First failed attempt sends exactly one error")

        // Revalidate the same request, as batch catch-up and the agent-join
        // poll do. The existing reply must suppress a duplicate.
        _ = await coordinator.processJoinRequestOutcomes(since: nil, client: creatorClient)
        errorCount = try await joinErrorCount(inDmWith: joinerClient.inboxID, client: creatorClient)
        #expect(errorCount == 1, "Reprocessing the same request must not send another error")

        // A fresh retry is a new attempt and deserves a new reply.
        try await Task.sleep(nanoseconds: 200_000_000)
        _ = try await coordinator.sendJoinRequest(for: invite.signedInvite, client: joinerClient)

        _ = try await creatorClient.conversations.syncAllConversations(consentStates: nil)
        _ = await coordinator.processJoinRequestOutcomes(since: nil, client: creatorClient)
        errorCount = try await joinErrorCount(inDmWith: joinerClient.inboxID, client: creatorClient)
        #expect(errorCount == 2, "A retried join request gets its own error reply")
    }

    /// Regression test for removed agents instantly rejoining: join-request
    /// DMs are durable, and batch catch-up / the agent-join poll revalidate
    /// them after the member list changes. Before the handled-request ledger,
    /// the only dedupe was "is the joiner currently a member", so removing
    /// the member made the already-honored request actionable again and the
    /// next pass silently re-added them. The ledger keys on message ID:
    /// the replayed request stays inert, while a fresh request with the same
    /// invite still joins (removal is not a block).
    @Test("Replayed join request does not re-add a removed member; a fresh request does")
    func replayedJoinRequestStaysInertAfterRemoval() async throws {
        let creatorClient = try await createClient()
        let joinerClient = try await createClient()
        defer {
            try? creatorClient.deleteLocalDatabase()
            try? joinerClient.deleteLocalDatabase()
        }
        // One ledger shared by two coordinator instances, mirroring how
        // production passes build a fresh coordinator per batch around the
        // shared database-backed store.
        let ledger = InMemoryHandledJoinRequestStore()
        let key = creatorInviteKey
        let firstPass = InviteCoordinator(privateKeyProvider: { _ in key }, handledRequestStore: ledger)

        let group = try await creatorClient.conversations.newGroup(with: [])
        try await group.updateConsentState(state: .allowed)
        _ = try await firstPass.revokeInvites(for: group)
        let invite = try await firstPass.createInvite(for: group, client: creatorClient)

        _ = try await firstPass.sendJoinRequest(for: invite.signedInvite, client: joinerClient)

        _ = try await creatorClient.conversations.syncAllConversations(consentStates: nil)
        let firstOutcomes = await firstPass.processJoinRequestOutcomes(since: nil, client: creatorClient)
        #expect(firstOutcomes.compactMap(\.joinResult).contains { $0.conversationId == group.id })

        try await group.removeMembers(inboxIds: [joinerClient.inboxID])
        var memberInboxIds = try await group.members.map(\.inboxId)
        #expect(!memberInboxIds.contains(joinerClient.inboxID))

        // Revalidate the full DM history, as batch catch-up and the
        // agent-join poll do after the removal.
        let secondPass = InviteCoordinator(privateKeyProvider: { _ in key }, handledRequestStore: ledger)
        let replayOutcomes = await secondPass.processJoinRequestOutcomes(since: nil, client: creatorClient)
        #expect(
            replayOutcomes.compactMap(\.joinResult).isEmpty,
            "Revalidating an already-honored join request must not re-add the removed member"
        )
        memberInboxIds = try await group.members.map(\.inboxId)
        #expect(
            !memberInboxIds.contains(joinerClient.inboxID),
            "Removed member must stay removed after revalidation passes"
        )

        // Removal is not a block: a fresh join request with the same valid
        // invite is a new attempt and joins again.
        try await Task.sleep(nanoseconds: 200_000_000)
        _ = try await secondPass.sendJoinRequest(for: invite.signedInvite, client: joinerClient)

        _ = try await creatorClient.conversations.syncAllConversations(consentStates: nil)
        let rejoinOutcomes = await secondPass.processJoinRequestOutcomes(since: nil, client: creatorClient)
        #expect(
            rejoinOutcomes.compactMap(\.joinResult).contains { $0.conversationId == group.id },
            "A fresh join request from a removed member must be honored"
        )
        memberInboxIds = try await group.members.map(\.inboxId)
        #expect(memberInboxIds.contains(joinerClient.inboxID), "Fresh request re-adds the removed member")
    }

    private func joinErrorCount(inDmWith peerInboxId: String, client: Client) async throws -> Int {
        let dm = try await client.conversations.findOrCreateDm(with: peerInboxId)
        let messages = try await dm.messages()
        return messages.filter { message in
            guard let contentType = try? message.encodedContent.type else { return false }
            return contentType == ContentTypeInviteJoinError
        }.count
    }
}
