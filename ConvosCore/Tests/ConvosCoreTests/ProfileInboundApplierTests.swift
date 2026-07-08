@testable import ConvosCore
import Foundation
import GRDB
import Testing

@Suite("ProfileInboundApplier")
struct ProfileInboundApplierTests {
    private let salt = Data(repeating: 1, count: 32)
    private let nonce = Data(repeating: 2, count: 12)
    private let key = Data(repeating: 3, count: 32)

    /// Full schema via the shared migrator, so the applier's canonical writes and
    /// the `DBContact` mirror both have their tables. Agent attestation /
    /// `hasHadVerifiedAgent` behaviour is exercised by the integration tests, so
    /// these tests use non-agent members.
    private func makeQueue(conversations: [String] = ["c1"]) throws -> DatabaseQueue {
        let queue = try DatabaseQueue()
        try SharedDatabaseMigrator.shared.migrate(database: queue)
        try queue.write { db in
            for id in conversations {
                try seedConversation(db, id: id)
            }
        }
        return queue
    }

    private func seedConversation(_ db: Database, id: String) throws {
        try DBMember(inboxId: "creator").save(db, onConflict: .ignore)
        try DBConversation(
            id: id,
            clientConversationId: id,
            inviteTag: "tag-\(id)",
            creatorId: "creator",
            kind: .group,
            consent: .allowed,
            createdAt: Date(),
            name: nil,
            description: nil,
            imageURLString: nil,
            publicImageURLString: nil,
            includeInfoInPublicPreview: true,
            expiresAt: nil,
            debugInfo: .empty,
            isLocked: false,
            imageSalt: nil,
            imageNonce: nil,
            imageEncryptionKey: nil,
            conversationEmoji: nil,
            imageLastRenewed: nil,
            isUnused: false,
            hasHadVerifiedAgent: false
        ).insert(db)
    }

    private func imageRef(url: String) -> EncryptedProfileImageRef {
        var ref = EncryptedProfileImageRef()
        ref.url = url
        ref.salt = salt
        ref.nonce = nonce
        return ref
    }

    private func apply(
        _ queue: DatabaseQueue,
        inboxId: String,
        source: ProfileSource = .profileUpdate,
        name: String?,
        avatar: ProfileInboundApplier.AvatarDisposition,
        metadata: ProfileMetadata? = nil,
        selfInboxId: String? = "me",
        fallbackKey: Data? = nil,
        sentAt: Date
    ) throws {
        try queue.write { db in
            try ProfileInboundApplier.apply(
                db: db,
                conversationId: "c1",
                event: ProfileInboundApplier.Incoming(
                    inboxId: inboxId,
                    source: source,
                    name: name,
                    avatar: avatar,
                    memberKind: nil,
                    metadata: metadata,
                    receivedAt: sentAt
                ),
                selfInboxId: selfInboxId,
                fallbackEncryptionKey: fallbackKey
            )
        }
    }

    private func profile(_ queue: DatabaseQueue, inboxId: String) throws -> DBProfile? {
        try queue.read { db in try DBProfile.fetchOne(db, inboxId: inboxId) }
    }

    private func avatar(_ queue: DatabaseQueue, inboxId: String) throws -> DBProfileAvatar? {
        try queue.read { db in try DBProfileAvatar.fetchOne(db, inboxId: inboxId, conversationId: "c1") }
    }

    @Test("an update writes identity and an avatar slot")
    func updateWritesIdentityAndAvatar() throws {
        let queue = try makeQueue()
        try apply(queue, inboxId: "alice", name: "Alice", avatar: .addressed(imageRef(url: "u")), fallbackKey: key, sentAt: Date(timeIntervalSince1970: 1))

        let alice = try profile(queue, inboxId: "alice")
        #expect(alice?.name == "Alice")
        #expect(alice?.profileSource == .profileUpdate)
        let slot = try avatar(queue, inboxId: "alice")
        #expect(slot?.url == "u")
        #expect(slot?.encryptionKey == key)
    }

    @Test("an event authored by the current user is not written to the profile tables")
    func selfEchoSkipped() throws {
        let queue = try makeQueue()
        try apply(queue, inboxId: "me", name: "Myself", avatar: .addressed(imageRef(url: "u")), selfInboxId: "me", sentAt: Date(timeIntervalSince1970: 1))

        let me = try profile(queue, inboxId: "me")
        #expect(me == nil)
        let slot = try avatar(queue, inboxId: "me")
        #expect(slot == nil)
    }

    @Test("a snapshot with no image leaves the avatar slot untouched")
    func snapshotFillIfPresentIsSilentWithoutImage() throws {
        let queue = try makeQueue()
        try apply(queue, inboxId: "alice", source: .profileSnapshot, name: "Alice", avatar: .fillIfPresent(nil), sentAt: Date(timeIntervalSince1970: 1))

        let alice = try profile(queue, inboxId: "alice")
        #expect(alice?.name == "Alice")
        let slot = try avatar(queue, inboxId: "alice")
        #expect(slot == nil)
    }

    @Test("an update with no image leaves an existing avatar untouched (deferred deliberate-clear)")
    func updateAddressedKeepsAvatarWhenImageAbsent() throws {
        let queue = try makeQueue()
        try apply(queue, inboxId: "alice", name: "Alice", avatar: .addressed(imageRef(url: "u")), fallbackKey: key, sentAt: Date(timeIntervalSince1970: 1))
        try apply(queue, inboxId: "alice", name: "Alice", avatar: .addressed(nil), sentAt: Date(timeIntervalSince1970: 2))

        // Until the wire format can signal a deliberate clear, an omitted image
        // is "no change", not a clear - so the existing avatar is preserved.
        let slot = try avatar(queue, inboxId: "alice")
        #expect(slot?.url == "u")
        #expect(slot?.encryptionKey == key)
    }

    @Test("an update with a malformed image ref leaves an existing avatar untouched")
    func updateAddressedKeepsAvatarWhenImageMalformed() throws {
        let queue = try makeQueue()
        try apply(queue, inboxId: "alice", name: "Alice", avatar: .addressed(imageRef(url: "u")), fallbackKey: key, sentAt: Date(timeIntervalSince1970: 1))
        // A set-but-invalid ref (no url) must never wipe a good avatar.
        var malformed = EncryptedProfileImageRef()
        malformed.salt = salt
        malformed.nonce = nonce
        try apply(queue, inboxId: "alice", name: "Alice", avatar: .addressed(malformed), sentAt: Date(timeIntervalSince1970: 2))

        let slot = try avatar(queue, inboxId: "alice")
        #expect(slot?.url == "u")
    }

    @Test("a lower-source snapshot does not override an update-sourced name")
    func precedenceHoldsThroughApplier() throws {
        let queue = try makeQueue()
        try apply(queue, inboxId: "alice", source: .profileUpdate, name: "Real", avatar: .fillIfPresent(nil), sentAt: Date(timeIntervalSince1970: 2))
        try apply(queue, inboxId: "alice", source: .profileSnapshot, name: "Snapshot", avatar: .fillIfPresent(nil), sentAt: Date(timeIntervalSince1970: 1))

        let alice = try profile(queue, inboxId: "alice")
        #expect(alice?.name == "Real")
        #expect(alice?.profileSource == .profileUpdate)
    }

    @Test("a nil selfInboxId still writes other members")
    func nilSelfStillWritesOthers() throws {
        let queue = try makeQueue()
        try apply(queue, inboxId: "alice", name: "Alice", avatar: .fillIfPresent(nil), selfInboxId: nil, sentAt: Date(timeIntervalSince1970: 1))

        let alice = try profile(queue, inboxId: "alice")
        #expect(alice?.name == "Alice")
    }

    @Test("an inbound update refreshes an existing contact's name and avatar")
    func mirrorsToExistingContact() throws {
        let queue = try makeQueue()
        try queue.write { db in
            try DBContact(
                inboxId: "alice",
                addedAt: Date(timeIntervalSince1970: 0),
                addedViaConversationId: "c1",
                displayName: "Old Alice",
                avatarURL: nil,
                profileUpdatedAt: Date(timeIntervalSince1970: 0)
            ).insert(db)
        }

        try apply(queue, inboxId: "alice", name: "New Alice", avatar: .addressed(imageRef(url: "u")), fallbackKey: key, sentAt: Date(timeIntervalSince1970: 1))

        let contact = try queue.read { db in try DBContact.fetchOne(db, key: "alice") }
        #expect(contact?.displayName == "New Alice")
        #expect(contact?.avatarURL == "u")
    }

    @Test("an inbound update does not create a contact for a non-contact member")
    func doesNotCreateContact() throws {
        let queue = try makeQueue()
        try apply(queue, inboxId: "bob", name: "Bob", avatar: .fillIfPresent(nil), sentAt: Date(timeIntervalSince1970: 1))

        let contact = try queue.read { db in try DBContact.fetchOne(db, key: "bob") }
        #expect(contact == nil)
    }

    @Test("a newer update's empty metadata map clears the stored metadata (revoked grants propagate)")
    func updateEmptyMetadataClears() throws {
        let queue = try makeQueue()
        try apply(queue, inboxId: "alice", name: "Alice", avatar: .addressed(nil), metadata: ["connections": .string("grants")], sentAt: Date(timeIntervalSince1970: 1))
        let seeded = try profile(queue, inboxId: "alice")
        #expect(seeded?.metadata?["connections"] == .string("grants"))

        // The sender revoked their last grant: the update's map is empty.
        try apply(queue, inboxId: "alice", name: "Alice", avatar: .addressed(nil), metadata: [:], sentAt: Date(timeIntervalSince1970: 2))

        let cleared = try profile(queue, inboxId: "alice")
        #expect(cleared?.metadata == nil)
    }

    @Test("a newer update's non-empty metadata map replaces the stored one wholesale")
    func updateMetadataReplacesWholesale() throws {
        let queue = try makeQueue()
        try apply(queue, inboxId: "alice", name: "Alice", avatar: .addressed(nil), metadata: ["connections": .string("grants")], sentAt: Date(timeIntervalSince1970: 1))
        try apply(queue, inboxId: "alice", name: "Alice", avatar: .addressed(nil), metadata: ["timezone": .string("Europe/Paris")], sentAt: Date(timeIntervalSince1970: 2))

        let replaced = try profile(queue, inboxId: "alice")
        #expect(replaced?.metadata?["timezone"] == .string("Europe/Paris"))
        #expect(replaced?.metadata?["connections"] == nil)
    }

    @Test("an older replayed update cannot clear newer metadata, and a snapshot never clears")
    func staleAndSnapshotEventsCannotClearMetadata() throws {
        let queue = try makeQueue()
        try apply(queue, inboxId: "alice", name: "Alice", avatar: .addressed(nil), metadata: ["connections": .string("grants")], sentAt: Date(timeIntervalSince1970: 5))

        // A replayed older update (empty map) loses on recency.
        try apply(queue, inboxId: "alice", name: "Alice", avatar: .addressed(nil), metadata: [:], sentAt: Date(timeIntervalSince1970: 1))
        // A snapshot path collapses empty to nil before the applier, so it says
        // nothing about metadata even when newer.
        try apply(queue, inboxId: "alice", source: .profileSnapshot, name: "Alice", avatar: .fillIfPresent(nil), metadata: nil, sentAt: Date(timeIntervalSince1970: 9))

        let kept = try profile(queue, inboxId: "alice")
        #expect(kept?.metadata?["connections"] == .string("grants"))
    }
}
