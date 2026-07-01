@testable import ConvosCore
import Foundation
import GRDB
import Testing

/// Coverage for `ConversationsRepository.findOneToOne(with:excluding:)` -
/// the SQL-pushed lookup that lets "Chat" on a contact card route into
/// an existing 1:1 instead of letting the picker create a duplicate.
@Suite("ConversationsRepository.findOneToOne Tests", .serialized)
struct ConversationsRepositoryFindOneToOneTests {
    private static let currentInboxId: String = "inbox-current"
    private static let otherInboxId: String = "inbox-other"

    /// Inserts a 1:1 between the current user and `other`, with all the
    /// rows `detailedConversationQuery` joins to as `required` (creator
    /// member + member profile, conversation local state). Returns the
    /// inserted conversation id so the caller can correlate it back.
    @discardableResult
    private static func seedOneToOne(
        db: Database,
        id: String,
        with other: String = otherInboxId,
        createdAt: Date,
        consent: Consent = .allowed,
        isUnused: Bool = false,
        expiresAt: Date? = nil,
        inviteTag: String? = nil
    ) throws -> String {
        try seedInbox(db: db)
        try DBMember(inboxId: other).save(db, onConflict: .ignore)

        try DBConversation(
            id: id,
            clientConversationId: "client-\(id)",
            inviteTag: inviteTag ?? "tag-\(id)",
            creatorId: currentInboxId,
            kind: .group,
            consent: consent,
            createdAt: createdAt,
            name: nil,
            description: nil,
            imageURLString: nil,
            publicImageURLString: nil,
            includeInfoInPublicPreview: false,
            expiresAt: expiresAt,
            debugInfo: .empty,
            isLocked: false,
            imageSalt: nil,
            imageNonce: nil,
            imageEncryptionKey: nil,
            conversationEmoji: nil,
            imageLastRenewed: nil,
            isUnused: isUnused,
            hasHadVerifiedAgent: false
        ).insert(db)

        try ConversationLocalState(
            conversationId: id,
            isPinned: false,
            isUnread: false,
            isUnreadUpdatedAt: createdAt,
            isMuted: false,
            pinnedOrder: nil,
            hidesInviteCard: false,
            leftHostedInviteSession: false,
            wasRemoved: false
        ).insert(db)

        try addMember(db: db, conversationId: id, inboxId: currentInboxId, role: .superAdmin)
        try addMember(db: db, conversationId: id, inboxId: other, role: .member)

        return id
    }

    private static func addMember(
        db: Database,
        conversationId: String,
        inboxId: String,
        role: MemberRole
    ) throws {
        try DBConversationMember(
            conversationId: conversationId,
            inboxId: inboxId,
            role: role,
            consent: .allowed,
            createdAt: Date(),
            invitedByInboxId: nil
        ).insert(db)
        try DBMemberProfile(
            conversationId: conversationId,
            inboxId: inboxId,
            name: inboxId,
            avatar: nil
        ).insert(db, onConflict: .ignore)
    }

    private static func seedInbox(db: Database) throws {
        try DBMember(inboxId: currentInboxId).save(db, onConflict: .ignore)
        try DBInbox(
            inboxId: currentInboxId,
            clientId: "client-current",
            createdAt: Date()
        ).save(db, onConflict: .ignore)
    }

    // MARK: - Tests

    @Test("Returns the existing 1:1 when one exists with the given inbox")
    func testReturnsExistingOneToOne() throws {
        let dbManager = MockDatabaseManager.makeTestDatabase()
        try dbManager.dbWriter.write { db in
            try Self.seedOneToOne(db: db, id: "convo-match", createdAt: Date())
        }

        let repo = ConversationsRepository(dbReader: dbManager.dbReader, consent: [.allowed])
        let match = try repo.findOneToOne(with: Self.otherInboxId, excluding: nil)

        #expect(match?.id == "convo-match")
        #expect(match?.membersWithoutCurrent.count == 1)
        #expect(match?.membersWithoutCurrent.first?.profile.inboxId == Self.otherInboxId)
    }

    @Test("Returns nil when no 1:1 exists with the given inbox")
    func testReturnsNilWhenNoMatch() throws {
        let dbManager = MockDatabaseManager.makeTestDatabase()
        try dbManager.dbWriter.write { db in
            try Self.seedOneToOne(db: db, id: "convo-with-someone-else", with: "inbox-someone-else", createdAt: Date())
        }

        let repo = ConversationsRepository(dbReader: dbManager.dbReader, consent: [.allowed])
        let match = try repo.findOneToOne(with: Self.otherInboxId, excluding: nil)

        #expect(match == nil)
    }

    @Test("Skips the excluded conversation so member-tap-from-inside-the-1:1 falls through to the picker")
    func testExcludingFiltersOutTheCurrentConversation() throws {
        let dbManager = MockDatabaseManager.makeTestDatabase()
        try dbManager.dbWriter.write { db in
            try Self.seedOneToOne(db: db, id: "convo-current", createdAt: Date())
        }

        let repo = ConversationsRepository(dbReader: dbManager.dbReader, consent: [.allowed])
        let match = try repo.findOneToOne(with: Self.otherInboxId, excluding: "convo-current")

        #expect(match == nil)
    }

    @Test("Returns the most-recently-created 1:1 when multiple match")
    func testMostRecentWinsWhenMultipleMatch() throws {
        let dbManager = MockDatabaseManager.makeTestDatabase()
        let older = Date(timeIntervalSince1970: 1_700_000_000)
        let newer = Date(timeIntervalSince1970: 1_800_000_000)

        try dbManager.dbWriter.write { db in
            try Self.seedOneToOne(db: db, id: "convo-older", createdAt: older)
            try Self.seedOneToOne(db: db, id: "convo-newer", createdAt: newer)
        }

        let repo = ConversationsRepository(dbReader: dbManager.dbReader, consent: [.allowed])
        let match = try repo.findOneToOne(with: Self.otherInboxId, excluding: nil)

        #expect(match?.id == "convo-newer")
    }

    @Test("Excluding the newest match lets the next-most-recent 1:1 surface")
    func testExcludingFallsThroughToNextMatch() throws {
        let dbManager = MockDatabaseManager.makeTestDatabase()
        let older = Date(timeIntervalSince1970: 1_700_000_000)
        let newer = Date(timeIntervalSince1970: 1_800_000_000)

        try dbManager.dbWriter.write { db in
            try Self.seedOneToOne(db: db, id: "convo-older", createdAt: older)
            try Self.seedOneToOne(db: db, id: "convo-newer", createdAt: newer)
        }

        let repo = ConversationsRepository(dbReader: dbManager.dbReader, consent: [.allowed])
        let match = try repo.findOneToOne(with: Self.otherInboxId, excluding: "convo-newer")

        #expect(match?.id == "convo-older")
    }

    @Test("Three-member group with the inbox does not count as a 1:1")
    func testGroupOfThreeIsNotAOneToOne() throws {
        let dbManager = MockDatabaseManager.makeTestDatabase()
        try dbManager.dbWriter.write { db in
            try Self.seedOneToOne(db: db, id: "convo-group", createdAt: Date())
            try DBMember(inboxId: "inbox-third").save(db, onConflict: .ignore)
            try Self.addMember(db: db, conversationId: "convo-group", inboxId: "inbox-third", role: .member)
        }

        let repo = ConversationsRepository(dbReader: dbManager.dbReader, consent: [.allowed])
        let match = try repo.findOneToOne(with: Self.otherInboxId, excluding: nil)

        #expect(match == nil)
    }

    @Test("Honours the consent scope - a denied 1:1 is not returned when querying allowed")
    func testConsentScopeHonoured() throws {
        let dbManager = MockDatabaseManager.makeTestDatabase()
        try dbManager.dbWriter.write { db in
            try Self.seedOneToOne(db: db, id: "convo-denied", createdAt: Date(), consent: .denied)
        }

        let repo = ConversationsRepository(dbReader: dbManager.dbReader, consent: [.allowed])
        #expect(try repo.findOneToOne(with: Self.otherInboxId, excluding: nil) == nil)

        let repoIncludingDenied = ConversationsRepository(
            dbReader: dbManager.dbReader,
            consent: [.allowed, .denied]
        )
        #expect(try repoIncludingDenied.findOneToOne(with: Self.otherInboxId, excluding: nil)?.id == "convo-denied")
    }

    @Test("Honours the [.allowed, .unknown] scope so a pending invite from this inbox matches")
    func testUnknownConsentInclusionMatches() throws {
        let dbManager = MockDatabaseManager.makeTestDatabase()
        try dbManager.dbWriter.write { db in
            try Self.seedOneToOne(db: db, id: "convo-pending", createdAt: Date(), consent: .unknown)
        }

        let repo = ConversationsRepository(dbReader: dbManager.dbReader, consent: [.allowed, .unknown])
        let match = try repo.findOneToOne(with: Self.otherInboxId, excluding: nil)

        #expect(match?.id == "convo-pending")
    }

    @Test("isUnused and expired rows are excluded")
    func testHiddenRowsAreExcluded() throws {
        let dbManager = MockDatabaseManager.makeTestDatabase()
        let now = Date()
        try dbManager.dbWriter.write { db in
            try Self.seedOneToOne(db: db, id: "convo-unused", createdAt: now, isUnused: true)
            try Self.seedOneToOne(db: db, id: "convo-expired", createdAt: now, expiresAt: Date(timeIntervalSince1970: 1))
        }

        let repo = ConversationsRepository(dbReader: dbManager.dbReader, consent: [.allowed])
        let match = try repo.findOneToOne(with: Self.otherInboxId, excluding: nil)

        #expect(match == nil)
    }

    @Test("Unsolicited stranger 1:1 stays hidden until its consent is promoted")
    func testStrangerConversationHiddenUntilConsentPromoted() throws {
        let dbManager = MockDatabaseManager.makeTestDatabase()
        try dbManager.dbWriter.write { db in
            try Self.seedOneToOneCreatedByOther(db: db, id: "convo-from-stranger", createdAt: Date(), consent: .unknown)
        }

        // Unsolicited stranger: consent stays `.unknown`, outside the
        // [.allowed] feed scope, so it's hidden.
        let repo = ConversationsRepository(dbReader: dbManager.dbReader, consent: [.allowed])
        #expect(try repo.findOneToOne(with: Self.otherInboxId, excluding: nil) == nil)

        // Promotion (ConversationConsentReconciler flips consent to .allowed
        // once the creator becomes a contact) brings it into the feed.
        try dbManager.dbWriter.write { db in
            try DBConversation
                .filter(DBConversation.Columns.id == "convo-from-stranger")
                .updateAll(db, DBConversation.Columns.consent.set(to: Consent.allowed))
        }
        #expect(try repo.findOneToOne(with: Self.otherInboxId, excluding: nil)?.id == "convo-from-stranger")
    }

    private static func seedOneToOneCreatedByOther(
        db: Database,
        id: String,
        createdAt: Date,
        consent: Consent = .unknown
    ) throws {
        try seedInbox(db: db)
        try DBMember(inboxId: otherInboxId).save(db, onConflict: .ignore)
        try DBConversation(
            id: id,
            clientConversationId: "client-\(id)",
            inviteTag: "tag-\(id)",
            creatorId: otherInboxId,
            kind: .group,
            consent: consent,
            createdAt: createdAt,
            name: nil,
            description: nil,
            imageURLString: nil,
            publicImageURLString: nil,
            includeInfoInPublicPreview: false,
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
        try ConversationLocalState(
            conversationId: id,
            isPinned: false,
            isUnread: false,
            isUnreadUpdatedAt: createdAt,
            isMuted: false,
            pinnedOrder: nil,
            hidesInviteCard: false,
            leftHostedInviteSession: false,
            wasRemoved: false
        ).insert(db)
        try addMember(db: db, conversationId: id, inboxId: currentInboxId, role: .member)
        try addMember(db: db, conversationId: id, inboxId: otherInboxId, role: .superAdmin)
    }
}
