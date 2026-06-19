@testable import ConvosCore
import Foundation
import GRDB
import Testing

/// Covers the most-recent-wins recency guard on `DBMemberProfile`
/// (`ContactsWriter.applyInboundMemberProfileInTransaction`). The bug this
/// guards against: an out-of-order or replayed older profile message
/// overwriting newer per-conversation profile data, and the member row
/// diverging from the mirrored contact row (which already had a recency guard).
@Suite("Member profile recency guard", .serialized)
struct MemberProfileRecencyTests {
    private static let convoId: String = "convo-1"
    private static let selfInboxId: String = "inbox-self"
    private static let otherInboxId: String = "inbox-other"

    private static let t0: Date = Date(timeIntervalSince1970: 1_000)
    private static let t1: Date = Date(timeIntervalSince1970: 2_000)
    private static let t2: Date = Date(timeIntervalSince1970: 3_000)
    private static let t3: Date = Date(timeIntervalSince1970: 4_000)

    /// Seeds the FK prerequisites (member + conversation) and an existing
    /// contact row stamped at `t0` so the mirror has a target to update.
    private static func seed(db: Database, withContact: Bool = true) throws {
        try DBMember(inboxId: otherInboxId).save(db, onConflict: .ignore)
        try DBConversation(
            id: convoId,
            clientConversationId: "client-\(convoId)",
            inviteTag: "tag-\(convoId)",
            creatorId: selfInboxId,
            kind: .group,
            consent: .allowed,
            createdAt: t0,
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
        ).insert(db, onConflict: .ignore)

        if withContact {
            try ContactsWriter.upsertContactInTransaction(
                db: db,
                inboxId: otherInboxId,
                addedViaConversationId: convoId,
                profile: ContactProfileSnapshot(displayName: "seed", profileUpdatedAt: t0)
            )
        }
    }

    private static func inbound(name: String) -> DBMemberProfile {
        DBMemberProfile(conversationId: Self.convoId, inboxId: Self.otherInboxId, name: name, avatar: nil)
    }

    private static func memberName(_ db: Database) throws -> String? {
        try DBMemberProfile.fetchOne(db, conversationId: convoId, inboxId: otherInboxId)?.name
    }

    private static func contactName(_ db: Database) throws -> String? {
        try DBContact.fetchOne(db, key: otherInboxId)?.displayName
    }

    @Test("older inbound is dropped; member stays newer and matches contact")
    func olderInboundDropped() throws {
        let dbManager = MockDatabaseManager.makeTestDatabase()
        try dbManager.dbWriter.write { db in
            try Self.seed(db: db)

            let appliedNewer = try ContactsWriter.applyInboundMemberProfileInTransaction(
                db: db, profile: Self.inbound(name: "Bravo-2"), incomingSentAt: Self.t2
            )
            #expect(appliedNewer)
            #expect(try Self.memberName(db) == "Bravo-2")
            #expect(try Self.contactName(db) == "Bravo-2")

            // Replay an older update after the newer one.
            let appliedOlder = try ContactsWriter.applyInboundMemberProfileInTransaction(
                db: db, profile: Self.inbound(name: "Bravo-1"), incomingSentAt: Self.t1
            )
            #expect(appliedOlder == false)
            // Member must not revert, and must still agree with the contact row.
            #expect(try Self.memberName(db) == "Bravo-2")
            #expect(try Self.contactName(db) == "Bravo-2")
        }
    }

    @Test("newer inbound updates an already-populated row")
    func newerInboundUpdates() throws {
        let dbManager = MockDatabaseManager.makeTestDatabase()
        try dbManager.dbWriter.write { db in
            try Self.seed(db: db)

            _ = try ContactsWriter.applyInboundMemberProfileInTransaction(
                db: db, profile: Self.inbound(name: "Bravo-2"), incomingSentAt: Self.t2
            )
            let applied = try ContactsWriter.applyInboundMemberProfileInTransaction(
                db: db, profile: Self.inbound(name: "Bravo-3"), incomingSentAt: Self.t3
            )
            #expect(applied)
            #expect(try Self.memberName(db) == "Bravo-3")
            #expect(try Self.contactName(db) == "Bravo-3")
        }
    }

    @Test("nil stored stamp accepts any timestamped inbound")
    func nilStoredStampAccepts() throws {
        let dbManager = MockDatabaseManager.makeTestDatabase()
        try dbManager.dbWriter.write { db in
            try Self.seed(db: db)
            // Placeholder row with no recency stamp (mirrors saveMembers / appData fill).
            try DBMemberProfile(conversationId: Self.convoId, inboxId: Self.otherInboxId, name: nil, avatar: nil)
                .insert(db, onConflict: .ignore)

            let applied = try ContactsWriter.applyInboundMemberProfileInTransaction(
                db: db, profile: Self.inbound(name: "Bravo-1"), incomingSentAt: Self.t1
            )
            #expect(applied)
            #expect(try Self.memberName(db) == "Bravo-1")
        }
    }

    @Test("equal timestamp applies (idempotent reprocess)")
    func equalTimestampApplies() throws {
        let dbManager = MockDatabaseManager.makeTestDatabase()
        try dbManager.dbWriter.write { db in
            try Self.seed(db: db)
            _ = try ContactsWriter.applyInboundMemberProfileInTransaction(
                db: db, profile: Self.inbound(name: "Bravo-2"), incomingSentAt: Self.t2
            )
            let applied = try ContactsWriter.applyInboundMemberProfileInTransaction(
                db: db, profile: Self.inbound(name: "Bravo-2b"), incomingSentAt: Self.t2
            )
            #expect(applied)
            #expect(try Self.memberName(db) == "Bravo-2b")
        }
    }

    @Test("a local edit stamped now is not clobbered by a stale echo")
    func localEditBeatsStaleEcho() throws {
        let dbManager = MockDatabaseManager.makeTestDatabase()
        try dbManager.dbWriter.write { db in
            try Self.seed(db: db)
            // Simulate a local write: row stamped at t3 (the user's own edit).
            try DBMemberProfile(conversationId: Self.convoId, inboxId: Self.otherInboxId, name: "Local", avatar: nil)
                .with(profileUpdatedAt: Self.t3)
                .save(db)

            // An older inbound echo (sent before the local edit) must be dropped.
            let applied = try ContactsWriter.applyInboundMemberProfileInTransaction(
                db: db, profile: Self.inbound(name: "Echo"), incomingSentAt: Self.t2
            )
            #expect(applied == false)
            #expect(try Self.memberName(db) == "Local")
        }
    }

    @Test("snapshot backfill populates a row with no recency stamp")
    func snapshotBackfillPopulatesUnstamped() throws {
        let dbManager = MockDatabaseManager.makeTestDatabase()
        try dbManager.dbWriter.write { db in
            try Self.seed(db: db)
            // Placeholder row with no recency stamp (never received a ProfileUpdate).
            try DBMemberProfile(conversationId: Self.convoId, inboxId: Self.otherInboxId, name: nil, avatar: nil)
                .insert(db, onConflict: .ignore)

            let applied = try ContactsWriter.applyInboundMemberProfileInTransaction(
                db: db, profile: Self.inbound(name: "Snap"), incomingSentAt: Self.t2, source: .snapshotBackfill
            )
            #expect(applied)
            #expect(try Self.memberName(db) == "Snap")
        }
    }

    @Test("snapshot backfill does not clobber a row an update already stamped, even when newer")
    func snapshotBackfillDoesNotClobberStamped() throws {
        let dbManager = MockDatabaseManager.makeTestDatabase()
        try dbManager.dbWriter.write { db in
            try Self.seed(db: db)

            // An authoritative ProfileUpdate lands first and stamps the row at t1.
            let update = try ContactsWriter.applyInboundMemberProfileInTransaction(
                db: db, profile: Self.inbound(name: "Update"), incomingSentAt: Self.t1
            )
            #expect(update)

            // A snapshot carries a later author-clock t2, but its per-member data
            // is not a valid recency signal; it must not overwrite the update.
            let snapshot = try ContactsWriter.applyInboundMemberProfileInTransaction(
                db: db, profile: Self.inbound(name: "StaleSnap"), incomingSentAt: Self.t2, source: .snapshotBackfill
            )
            #expect(snapshot == false)
            #expect(try Self.memberName(db) == "Update")
            #expect(try Self.contactName(db) == "Update")
        }
    }

    @Test("mirror no-ops when there is no contact row (no auto-add)")
    func noContactRowIsNoOp() throws {
        let dbManager = MockDatabaseManager.makeTestDatabase()
        try dbManager.dbWriter.write { db in
            try Self.seed(db: db, withContact: false)
            let applied = try ContactsWriter.applyInboundMemberProfileInTransaction(
                db: db, profile: Self.inbound(name: "Bravo-2"), incomingSentAt: Self.t2
            )
            #expect(applied)
            #expect(try Self.memberName(db) == "Bravo-2")
            #expect(try DBContact.fetchOne(db, key: Self.otherInboxId) == nil)
        }
    }
}
