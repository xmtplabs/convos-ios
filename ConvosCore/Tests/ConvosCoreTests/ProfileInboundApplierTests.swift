@testable import ConvosCore
import Foundation
import GRDB
import Testing

@Suite("ProfileInboundApplier")
struct ProfileInboundApplierTests {
    private let salt = Data(repeating: 1, count: 32)
    private let nonce = Data(repeating: 2, count: 12)
    private let key = Data(repeating: 3, count: 32)

    /// Minimal schema: the profile tables plus the `member` and `conversation`
    /// tables the applier touches. Agent attestation / `hasHadVerifiedAgent`
    /// behaviour is exercised by the integration tests, so these tests use
    /// non-agent members and the conversation table only needs its id.
    private func makeQueue(conversations: [String] = ["c1"]) throws -> DatabaseQueue {
        let queue = try DatabaseQueue()
        try queue.write { db in
            try db.create(table: "conversation") { t in
                t.column("id", .text).notNull().primaryKey()
            }
            try db.create(table: "member") { t in
                t.column("inboxId", .text).notNull().primaryKey()
            }
            try SharedDatabaseMigrator.createProfileTables(db)
            for id in conversations {
                try db.execute(sql: "INSERT INTO conversation (id) VALUES (?)", arguments: [id])
            }
        }
        return queue
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
                    metadata: nil,
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

    @Test("an update with no image clears an existing avatar slot")
    func updateAddressedClearsAvatar() throws {
        let queue = try makeQueue()
        try apply(queue, inboxId: "alice", name: "Alice", avatar: .addressed(imageRef(url: "u")), fallbackKey: key, sentAt: Date(timeIntervalSince1970: 1))
        try apply(queue, inboxId: "alice", name: "Alice", avatar: .addressed(nil), sentAt: Date(timeIntervalSince1970: 2))

        let slot = try avatar(queue, inboxId: "alice")
        #expect(slot != nil)
        #expect(slot?.url == nil)
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
}
