@testable import ConvosCore
import Foundation
import Testing
@preconcurrency import XMTPiOS

/// Covers the verification core shared by the main stream's fast path and
/// the NSE's push paths: a join request only surfaces when its slug is a
/// valid, unexpired invite signed by this device's own identity key.
@Suite("Pairing Join Request Detector")
struct PairingJoinRequestDetectorTests {
    private func makeIdentity(inboxId: String = "own-inbox") throws -> KeychainIdentity {
        let keys = try KeychainIdentityKeys.generate()
        return KeychainIdentity(inboxId: inboxId, clientId: UUID().uuidString, keys: keys)
    }

    private func mintSlug(
        inboxId: String,
        privateKey: PrivateKey,
        expiresAt: Date = Date().addingTimeInterval(300)
    ) async throws -> String {
        let invite = try await PairingInvite.signed(
            initiatorInboxId: inboxId,
            privateKey: privateKey,
            expiresAt: expiresAt
        )
        return try invite.toURLSafeSlug()
    }

    @Test("Self-signed unexpired slug from another inbox verifies")
    func selfSignedSlugVerifies() async throws {
        let identity = try makeIdentity()
        let slug = try await mintSlug(inboxId: identity.inboxId, privateKey: identity.keys.privateKey)

        #expect(PairingJoinRequestDetector.verify(slug: slug, senderInboxId: "joiner-x", identity: identity))
    }

    @Test("Slug signed by a foreign key naming our inboxId is rejected")
    func foreignKeySlugIsRejected() async throws {
        let identity = try makeIdentity()
        let attackerKey = try PrivateKey.generate()
        // The attacker can put our inboxId in the slug, but the signature
        // recovers to the attacker's own address, not our key's.
        let slug = try await mintSlug(inboxId: identity.inboxId, privateKey: attackerKey)

        #expect(!PairingJoinRequestDetector.verify(slug: slug, senderInboxId: "joiner-x", identity: identity))
    }

    @Test("Expired slug is rejected")
    func expiredSlugIsRejected() async throws {
        let identity = try makeIdentity()
        let slug = try await mintSlug(
            inboxId: identity.inboxId,
            privateKey: identity.keys.privateKey,
            expiresAt: Date().addingTimeInterval(-60)
        )

        #expect(!PairingJoinRequestDetector.verify(slug: slug, senderInboxId: "joiner-x", identity: identity))
    }

    @Test("Request sent by our own inbox is rejected")
    func selfSenderIsRejected() async throws {
        let identity = try makeIdentity()
        let slug = try await mintSlug(inboxId: identity.inboxId, privateKey: identity.keys.privateKey)

        #expect(!PairingJoinRequestDetector.verify(slug: slug, senderInboxId: identity.inboxId, identity: identity))
    }

    @Test("Slug for a different inboxId is rejected")
    func differentInboxIdIsRejected() async throws {
        let identity = try makeIdentity()
        let slug = try await mintSlug(inboxId: "someone-else", privateKey: identity.keys.privateKey)

        #expect(!PairingJoinRequestDetector.verify(slug: slug, senderInboxId: "joiner-x", identity: identity))
    }

    @Test("Garbage slug is rejected")
    func garbageSlugIsRejected() throws {
        let identity = try makeIdentity()

        #expect(!PairingJoinRequestDetector.verify(slug: "not-a-slug", senderInboxId: "joiner-x", identity: identity))
    }
}

@Suite("Pending Pair Request Store")
struct PendingPairRequestStoreTests {
    // Tests run in parallel; each gets its own defaults suite so writes
    // can't bleed between them.
    private func clearSuite(_ suite: String) {
        UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite)
    }

    @Test("Round-trips a pending request through set, peek, and consume")
    func roundTrips() {
        let suite = "pending-pair-request-store-tests-roundtrip"
        clearSuite(suite)
        defer { clearSuite(suite) }
        let pending = PendingPairRequestStore.Pending(
            joinerInboxId: "joiner-a",
            deviceName: "Joiner Phone",
            receivedAt: Date(timeIntervalSince1970: 1_000)
        )

        PendingPairRequestStore.setPending(pending, appGroup: suite)
        #expect(PendingPairRequestStore.pending(appGroup: suite) == pending)
        // Peeking doesn't clear.
        #expect(PendingPairRequestStore.pending(appGroup: suite) == pending)

        #expect(PendingPairRequestStore.consumePending(appGroup: suite) == pending)
        #expect(PendingPairRequestStore.pending(appGroup: suite) == nil)
        #expect(PendingPairRequestStore.consumePending(appGroup: suite) == nil)
    }

    @Test("An undecodable stash is left in place for the next resend to overwrite")
    func undecodableStashIsNotDestroyed() {
        let suite = "pending-pair-request-store-tests-corrupt"
        clearSuite(suite)
        defer { clearSuite(suite) }
        let defaults = UserDefaults(suiteName: suite)
        defaults?.set(Data("not json".utf8), forKey: "convos.pairing.pendingJoinRequest.v1")

        #expect(PendingPairRequestStore.consumePending(appGroup: suite) == nil)
        // The blob survives the failed consume...
        #expect(defaults?.data(forKey: "convos.pairing.pendingJoinRequest.v1") != nil)

        // ...and the joiner's next resend replaces it with a good one.
        let pending = PendingPairRequestStore.Pending(
            joinerInboxId: "joiner-a",
            deviceName: "Joiner Phone",
            receivedAt: Date(timeIntervalSince1970: 1_000)
        )
        PendingPairRequestStore.setPending(pending, appGroup: suite)
        #expect(PendingPairRequestStore.consumePending(appGroup: suite) == pending)
    }

    @Test("A newer request replaces the previous one")
    func newerRequestReplaces() {
        let suite = "pending-pair-request-store-tests-replace"
        clearSuite(suite)
        defer { clearSuite(suite) }
        let first = PendingPairRequestStore.Pending(
            joinerInboxId: "joiner-a", deviceName: "First", receivedAt: Date(timeIntervalSince1970: 1_000)
        )
        let second = PendingPairRequestStore.Pending(
            joinerInboxId: "joiner-b", deviceName: "Second", receivedAt: Date(timeIntervalSince1970: 2_000)
        )

        PendingPairRequestStore.setPending(first, appGroup: suite)
        PendingPairRequestStore.setPending(second, appGroup: suite)

        #expect(PendingPairRequestStore.consumePending(appGroup: suite) == second)
    }
}
