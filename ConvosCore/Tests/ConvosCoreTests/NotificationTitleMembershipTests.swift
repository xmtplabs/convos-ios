@testable import ConvosCore
import Foundation
import GRDB
import Testing

@Suite("Notification title excludes removed members")
struct NotificationTitleMembershipTests {
    private let conversationId: String = "conversation-1"
    private let currentInboxId: String = "current-user"
    private let presentInboxId: String = "present-member"
    private let orphanInboxId: String = "removed-member"

    private func seedConversation(db: Database) throws {
        for inboxId in [currentInboxId, presentInboxId, orphanInboxId] {
            try DBMember(inboxId: inboxId).save(db, onConflict: .ignore)
        }
        try DBConversation(
            id: conversationId,
            clientConversationId: "client-\(conversationId)",
            inviteTag: "invite-tag-\(conversationId)",
            creatorId: currentInboxId,
            kind: .group,
            consent: .allowed,
            createdAt: Date(),
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
            hasHadVerifiedAgent: false,
        ).insert(db)
    }

    /// Seeds a member's canonical identity. `computedDisplayName` resolves names
    /// from `DBProfile` (per-inbox), gated on current `conversation_members`
    /// membership - so an orphan with a profile but no membership row is still
    /// excluded from the title.
    private func seedMemberProfile(db: Database, inboxId: String, name: String?, memberKind: DBMemberKind? = nil) throws {
        try DBProfile(
            inboxId: inboxId,
            name: name,
            memberKind: memberKind,
            profileSource: .profileUpdate,
            updatedAt: Date()
        ).save(db)
    }

    private func seedConversationMember(db: Database, inboxId: String, role: MemberRole) throws {
        try DBConversationMember(
            conversationId: conversationId,
            inboxId: inboxId,
            role: role,
            consent: .allowed,
            createdAt: Date(),
            invitedByInboxId: nil
        ).insert(db)
    }

    /// Seeds a conversation with the current user plus one present member and
    /// one orphan member. The orphan keeps a `DBMemberProfile` row (as a real
    /// removal leaves behind for historical sender attribution) but has no
    /// `DBConversationMember` row, reproducing the stale-title bug.
    private func seedRemovedMemberScenario(db: Database) throws {
        try seedConversation(db: db)

        try seedMemberProfile(db: db, inboxId: currentInboxId, name: "Me")
        try seedMemberProfile(db: db, inboxId: presentInboxId, name: "Kai")
        try seedMemberProfile(db: db, inboxId: orphanInboxId, name: "Berry Bowl Bliss", memberKind: .agent)

        try seedConversationMember(db: db, inboxId: currentInboxId, role: .superAdmin)
        try seedConversationMember(db: db, inboxId: presentInboxId, role: .member)
    }

    @Test("Computed title excludes a removed member whose profile is orphaned")
    func computedTitleExcludesOrphanProfile() throws {
        let dbManager = MockDatabaseManager.makeTestDatabase()
        try dbManager.dbWriter.write { db in
            try seedRemovedMemberScenario(db: db)
        }
        let title = try dbManager.dbReader.read { db in
            try MessagingService.computedDisplayName(
                db: db,
                conversationId: conversationId,
                currentInboxId: currentInboxId
            )
        }
        #expect(title == "Kai")
    }

    @Test("Other-member count is gated on current membership, not profiles")
    func otherMemberCountExcludesOrphanProfile() throws {
        let dbManager = MockDatabaseManager.makeTestDatabase()
        try dbManager.dbWriter.write { db in
            try seedRemovedMemberScenario(db: db)
        }
        let count = try dbManager.dbReader.read { db in
            try MessagingService.otherMemberCount(
                db: db,
                conversationId: conversationId,
                currentInboxId: currentInboxId
            )
        }
        #expect(count == 1)
    }

    @Test("Present members are unaffected by the membership gate")
    func presentMembersStillResolve() throws {
        let dbManager = MockDatabaseManager.makeTestDatabase()
        try dbManager.dbWriter.write { db in
            try seedConversation(db: db)
            try seedMemberProfile(db: db, inboxId: currentInboxId, name: "Me")
            try seedMemberProfile(db: db, inboxId: presentInboxId, name: "Kai")
            try seedMemberProfile(db: db, inboxId: orphanInboxId, name: "Ada")
            try seedConversationMember(db: db, inboxId: currentInboxId, role: .superAdmin)
            try seedConversationMember(db: db, inboxId: presentInboxId, role: .member)
            try seedConversationMember(db: db, inboxId: orphanInboxId, role: .member)
        }
        let result = try dbManager.dbReader.read { db -> (String, Int) in
            let title = try MessagingService.computedDisplayName(
                db: db,
                conversationId: conversationId,
                currentInboxId: currentInboxId
            )
            let count = try MessagingService.otherMemberCount(
                db: db,
                conversationId: conversationId,
                currentInboxId: currentInboxId
            )
            return (title, count)
        }
        #expect(result.0 == "Ada, Kai")
        #expect(result.1 == 2)
    }
}
