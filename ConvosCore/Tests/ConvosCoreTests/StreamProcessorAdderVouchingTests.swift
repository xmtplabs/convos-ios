@testable import ConvosCore
import Foundation
import GRDB
import Testing

/// Coverage for `StreamProcessor.contactsVouch` - the trust decision behind the
/// `.unknown -> .allowed` consent bump on an inbound welcome.
///
/// A conversation is consented to on the local user's behalf when someone they
/// trust is responsible for it: the inbox that *added* them, or the group's
/// creator. Those differ whenever a contact adds you to a group somebody else
/// made, which is the case the creator-only rule used to get wrong.
///
/// The adder lookup is a local libxmtp read that can fail. A failed read is not
/// the same as "there is no adder", and collapsing the two would let a blocked
/// inviter's welcome through on the creator's contact status alone.
@Suite("StreamProcessor adder vouching", .serialized)
struct StreamProcessorAdderVouchingTests {
    private static let creator: String = "creator-inbox"
    private static let adder: String = "adder-inbox"
    private static let client: String = "client-inbox"

    @Test("A non-blocked contact who added us vouches, even when the creator is a stranger")
    func testKnownContactAdderVouches() async throws {
        let dbManager = MockDatabaseManager.makeTestDatabase()
        try await dbManager.dbWriter.write { db in
            try Self.seedContact(db: db, inboxId: Self.adder, blockedAt: nil)
        }

        let vouched = try await StreamProcessor.contactsVouch(
            adder: .known(Self.adder),
            creatorInboxId: Self.creator,
            clientInboxId: Self.client,
            databaseReader: dbManager.dbReader
        )

        #expect(vouched)
    }

    @Test("A non-blocked contact creator vouches for a row that predates the adder column")
    func testContactCreatorVouchesWhenAdderNotRecorded() async throws {
        let dbManager = MockDatabaseManager.makeTestDatabase()
        try await dbManager.dbWriter.write { db in
            try Self.seedContact(db: db, inboxId: Self.creator, blockedAt: nil)
        }

        let vouched = try await StreamProcessor.contactsVouch(
            adder: .notRecorded,
            creatorInboxId: Self.creator,
            clientInboxId: Self.client,
            databaseReader: dbManager.dbReader
        )

        #expect(vouched)
    }

    @Test("A non-blocked contact creator vouches when there is genuinely no adder")
    func testContactCreatorVouchesWhenNoAdder() async throws {
        // A foreign creator here is logged as an anomaly but deliberately still
        // vouches - see `contactsVouch`.
        let dbManager = MockDatabaseManager.makeTestDatabase()
        try await dbManager.dbWriter.write { db in
            try Self.seedContact(db: db, inboxId: Self.creator, blockedAt: nil)
        }

        let vouched = try await StreamProcessor.contactsVouch(
            adder: .none,
            creatorInboxId: Self.creator,
            clientInboxId: Self.client,
            databaseReader: dbManager.dbReader
        )

        #expect(vouched)
    }

    @Test("An unresolved adder never vouches, even when the creator is a contact")
    func testUnresolvedAdderNeverVouches() async throws {
        // The regression: a failed adder read used to degrade to nil and fall
        // back to creator-only, so a blocked inviter reached the local user on
        // the creator's contact status. We can't rule that out, so we decline
        // to consent and leave the conversation at `.unknown` (hidden).
        let dbManager = MockDatabaseManager.makeTestDatabase()
        try await dbManager.dbWriter.write { db in
            try Self.seedContact(db: db, inboxId: Self.creator, blockedAt: nil)
            // The (unreadable) adder happens to be blocked - the case the
            // fail-closed rule exists to protect.
            try Self.seedContact(db: db, inboxId: Self.adder, blockedAt: Date())
        }

        let vouched = try await StreamProcessor.contactsVouch(
            adder: .unresolved,
            creatorInboxId: Self.creator,
            clientInboxId: Self.client,
            databaseReader: dbManager.dbReader
        )

        #expect(!vouched)
    }

    @Test("A blocked adder blocks vouching even when the creator is a contact")
    func testBlockedAdderVetoesContactCreator() async throws {
        let dbManager = MockDatabaseManager.makeTestDatabase()
        try await dbManager.dbWriter.write { db in
            try Self.seedContact(db: db, inboxId: Self.creator, blockedAt: nil)
            try Self.seedContact(db: db, inboxId: Self.adder, blockedAt: Date())
        }

        let vouched = try await StreamProcessor.contactsVouch(
            adder: .known(Self.adder),
            creatorInboxId: Self.creator,
            clientInboxId: Self.client,
            databaseReader: dbManager.dbReader
        )

        #expect(!vouched)
    }

    @Test("A blocked creator blocks vouching even when a contact added us")
    func testBlockedCreatorVetoesContactAdder() async throws {
        let dbManager = MockDatabaseManager.makeTestDatabase()
        try await dbManager.dbWriter.write { db in
            try Self.seedContact(db: db, inboxId: Self.creator, blockedAt: Date())
            try Self.seedContact(db: db, inboxId: Self.adder, blockedAt: nil)
        }

        let vouched = try await StreamProcessor.contactsVouch(
            adder: .known(Self.adder),
            creatorInboxId: Self.creator,
            clientInboxId: Self.client,
            databaseReader: dbManager.dbReader
        )

        #expect(!vouched)
    }

    @Test("Strangers on both sides do not vouch")
    func testStrangersDoNotVouch() async throws {
        let dbManager = MockDatabaseManager.makeTestDatabase()

        let vouched = try await StreamProcessor.contactsVouch(
            adder: .known(Self.adder),
            creatorInboxId: Self.creator,
            clientInboxId: Self.client,
            databaseReader: dbManager.dbReader
        )

        #expect(!vouched)
    }

    private static func seedContact(db: Database, inboxId: String, blockedAt: Date?) throws {
        try DBContact(
            inboxId: inboxId,
            addedAt: Date(),
            addedViaConversationId: nil,
            displayName: nil,
            avatarURL: nil,
            avatarSalt: nil,
            avatarNonce: nil,
            avatarKey: nil,
            profileUpdatedAt: Date(),
            blockedAt: blockedAt,
            agentVerification: nil
        ).insert(db)
    }
}
