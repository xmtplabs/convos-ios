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
        let options = ClientOptions(
            api: .init(env: .local, appVersion: "convos-tests/1.0.0"),
            codecs: [
                TextCodec(),
                JoinRequestCodec(),
                InviteJoinErrorCodec(),
            ],
            dbEncryptionKey: dbKey
        )
        return try await Client.createInMemory(
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
}
