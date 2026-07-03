@testable import ConvosCore
import Foundation
import GRDB
import Testing

/// Coverage for the self-identity fallback in `DBConversationMemberProfileWithRole`.
/// The current user is excluded from the canonical `profile` table, so both the
/// member `profile` join and the `inviterProfile` join are nil for self. These
/// tests lock in that hydration falls back to the locally-authored `myProfile`
/// so the current user does not render as "Somebody" as a member or inviter.
@Suite("ConversationMember self-profile fallback", .serialized)
struct ConversationMemberSelfProfileTests {
    private static let selfInboxId: String = "me"
    private static let otherInboxId: String = "alice"
    private static let conversationId: String = "c1"

    private func makeDatabase() throws -> DatabaseQueue {
        let dbQueue = try DatabaseQueue()
        try SharedDatabaseMigrator.shared.migrate(database: dbQueue)
        return dbQueue
    }

    private func seedConversation(_ db: Database) throws {
        for inboxId in [Self.selfInboxId, Self.otherInboxId] {
            try DBMember(inboxId: inboxId).save(db, onConflict: .ignore)
        }
        try DBInbox(inboxId: Self.selfInboxId, clientId: "client-me", createdAt: Date()).save(db, onConflict: .ignore)
        try DBConversation(
            id: Self.conversationId,
            clientConversationId: Self.conversationId,
            inviteTag: "tag",
            creatorId: Self.selfInboxId,
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

    private func addMember(_ db: Database, inboxId: String, invitedBy: String? = nil) throws {
        try DBConversationMember(
            conversationId: Self.conversationId,
            inboxId: inboxId,
            role: inboxId == Self.selfInboxId ? .superAdmin : .member,
            consent: .allowed,
            createdAt: Date(),
            invitedByInboxId: invitedBy
        ).insert(db)
    }

    @Test("self member falls back to the myProfile name instead of Somebody")
    func selfMemberUsesSelfProfileName() async throws {
        let db = try makeDatabase()
        try await db.write { db in
            try seedConversation(db)
            try addMember(db, inboxId: Self.selfInboxId)
            try addMember(db, inboxId: Self.otherInboxId)
            // Alice has a canonical profile; self is excluded from `profile` and
            // only exists in `myProfile`.
            try DBProfile(inboxId: Self.otherInboxId, name: "Alice", profileSource: .profileUpdate, updatedAt: Date()).save(db)
            try DBMyProfile(inboxId: Self.selfInboxId, name: "Me").save(db)
        }

        let rows = try await db.read { db in
            try DBConversationMemberProfileWithRole.fetchAll(
                db, conversationId: Self.conversationId, inboxIds: [Self.selfInboxId, Self.otherInboxId]
            )
        }

        let selfRow = try #require(rows.first { $0.inboxId == Self.selfInboxId })
        let aliceRow = try #require(rows.first { $0.inboxId == Self.otherInboxId })
        #expect(selfRow.hydratedProfile().displayName == "Me")
        #expect(aliceRow.hydratedProfile().displayName == "Alice")
    }

    @Test("inviter that is the current user resolves invitedBy from myProfile")
    func inviterSelfResolvesInvitedBy() async throws {
        let db = try makeDatabase()
        try await db.write { db in
            try seedConversation(db)
            try addMember(db, inboxId: Self.selfInboxId)
            try addMember(db, inboxId: Self.otherInboxId, invitedBy: Self.selfInboxId)
            try DBProfile(inboxId: Self.otherInboxId, name: "Alice", profileSource: .profileUpdate, updatedAt: Date()).save(db)
            try DBMyProfile(inboxId: Self.selfInboxId, name: "Me").save(db)
        }

        let aliceRow = try await db.read { db in
            try #require(try DBConversationMemberProfileWithRole.fetchOne(
                db, conversationId: Self.conversationId, inboxId: Self.otherInboxId
            ))
        }

        let member = aliceRow.hydrateConversationMember(currentInboxId: Self.selfInboxId)
        #expect(member.invitedBy?.inboxId == Self.selfInboxId)
    }

    @Test("a non-self member with a canonical profile is unaffected by the self join")
    func nonSelfMemberUnaffected() async throws {
        let db = try makeDatabase()
        try await db.write { db in
            try seedConversation(db)
            try addMember(db, inboxId: Self.otherInboxId)
            try DBProfile(inboxId: Self.otherInboxId, name: "Alice", profileSource: .profileUpdate, updatedAt: Date()).save(db)
        }

        let aliceRow = try await db.read { db in
            try #require(try DBConversationMemberProfileWithRole.fetchOne(
                db, conversationId: Self.conversationId, inboxId: Self.otherInboxId
            ))
        }
        #expect(aliceRow.myProfile == nil)
        #expect(aliceRow.hydratedProfile().displayName == "Alice")
    }
}
