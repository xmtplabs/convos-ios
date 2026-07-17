@testable import ConvosCore
import Foundation
import GRDB
import Testing

@Suite("Notification member display name resolution")
struct NotificationMemberDisplayNameTests {
    private let conversationId: String = "conversation-1"
    private let memberInboxId: String = "member-1"

    private func seedConversation(db: Database) throws {
        try DBMember(inboxId: memberInboxId).save(db, onConflict: .ignore)
        try DBConversation(
            id: conversationId,
            clientConversationId: "client-\(conversationId)",
            inviteTag: "invite-tag-\(conversationId)",
            creatorId: memberInboxId,
            kind: .group,
            consent: .allowed,
            createdAt: Date(),
            name: "Test",
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

    /// Seeds the member's canonical identity. `notificationMemberDisplayName`
    /// reads `DBProfile` (per-inbox), not the legacy per-conversation
    /// `DBMemberProfile`.
    private func seedMemberProfile(db: Database, name: String?, memberKind: DBMemberKind? = nil) throws {
        try DBProfile(
            inboxId: memberInboxId,
            name: name,
            memberKind: memberKind,
            profileSource: .profileUpdate,
            updatedAt: Date()
        ).save(db)
    }

    private func seedContact(db: Database, displayName: String?) throws {
        try DBContact(
            inboxId: memberInboxId,
            addedAt: Date(),
            addedViaConversationId: nil,
            displayName: displayName
        ).save(db)
    }

    private func resolve(_ dbManager: MockDatabaseManager) throws -> String {
        try dbManager.dbReader.read { db in
            try MessagingService.notificationMemberDisplayName(
                db: db,
                inboxId: memberInboxId,
                conversationId: conversationId
            )
        }
    }

    @Test("Contact name wins over per-conversation profile name")
    func contactNameWinsOverProfileName() throws {
        let dbManager = MockDatabaseManager.makeTestDatabase()
        try dbManager.dbWriter.write { db in
            try seedConversation(db: db)
            try seedMemberProfile(db: db, name: "ProfileName")
            try seedContact(db: db, displayName: "ContactName")
        }
        #expect(try resolve(dbManager) == "ContactName")
    }

    @Test("Contact name fills in when the conversation has no profile row")
    func contactNameFillsMissingProfile() throws {
        let dbManager = MockDatabaseManager.makeTestDatabase()
        try dbManager.dbWriter.write { db in
            try seedConversation(db: db)
            try seedContact(db: db, displayName: "ContactName")
        }
        #expect(try resolve(dbManager) == "ContactName")
    }

    @Test("Profile name is used when there is no contact row")
    func profileNameWhenNoContact() throws {
        let dbManager = MockDatabaseManager.makeTestDatabase()
        try dbManager.dbWriter.write { db in
            try seedConversation(db: db)
            try seedMemberProfile(db: db, name: "ProfileName")
        }
        #expect(try resolve(dbManager) == "ProfileName")
    }

    @Test("Nameless contact falls through to profile name")
    func namelessContactFallsThroughToProfileName() throws {
        let dbManager = MockDatabaseManager.makeTestDatabase()
        try dbManager.dbWriter.write { db in
            try seedConversation(db: db)
            try seedMemberProfile(db: db, name: "ProfileName")
            try seedContact(db: db, displayName: nil)
        }
        #expect(try resolve(dbManager) == "ProfileName")
    }

    @Test("No contact and no profile name resolves to Somebody")
    func noNamesResolvesToSomebody() throws {
        let dbManager = MockDatabaseManager.makeTestDatabase()
        try dbManager.dbWriter.write { db in
            try seedConversation(db: db)
            try seedMemberProfile(db: db, name: nil)
        }
        #expect(try resolve(dbManager) == "Somebody")
    }

    @Test("Unknown inbox with no rows at all resolves to Somebody")
    func unknownInboxResolvesToSomebody() throws {
        let dbManager = MockDatabaseManager.makeTestDatabase()
        try dbManager.dbWriter.write { db in
            try seedConversation(db: db)
        }
        #expect(try resolve(dbManager) == "Somebody")
    }

    @Test("Nameless agent resolves to Agent")
    func namelessAgentResolvesToAgent() throws {
        let dbManager = MockDatabaseManager.makeTestDatabase()
        try dbManager.dbWriter.write { db in
            try seedConversation(db: db)
            try seedMemberProfile(db: db, name: nil, memberKind: .agent)
        }
        #expect(try resolve(dbManager) == "Agent")
    }
}
