@testable import ConvosCore
import Foundation
import GRDB
import Testing

/// Guards `SharedDatabaseMigrator.backfillContactAgentTemplateFieldsFromMemberProfiles`,
/// the one-time upgrade backfill that restores agent contacts which predate the
/// `contact.agentTemplateId` column. Without it an existing agent contact keeps a
/// null templateId after upgrade and is hidden from the contacts list until a fresh
/// ProfileUpdate re-mirrors the value. The templateId is read from the agent's
/// per-conversation `memberProfile.metadata`, which is already on disk.
@Suite("Agent template backfill migration", .serialized)
struct AgentTemplateBackfillMigrationTests {
    private func seedConversationAndMember(
        db: Database,
        conversationId: String,
        inboxId: String
    ) throws {
        try DBMember(inboxId: inboxId).save(db, onConflict: .ignore)
        try db.execute(
            sql: """
                INSERT INTO conversation (id, clientConversationId, inviteTag, creatorId, kind, consent, createdAt)
                VALUES (?, ?, ?, ?, ?, ?, ?)
                """,
            arguments: [conversationId, conversationId, "tag-\(conversationId)", inboxId, "group", "allowed", Date()]
        )
    }

    private func runBackfill(_ dbManager: any DatabaseManagerProtocol) async throws {
        try await dbManager.dbWriter.write { db in
            try SharedDatabaseMigrator.backfillContactAgentTemplateFieldsFromMemberProfiles(db)
        }
    }

    private func fetchContact(_ db: Database, _ inboxId: String) throws -> DBContact? {
        try DBContact.fetchOne(db, sql: "SELECT * FROM contact WHERE inboxId = ?", arguments: [inboxId])
    }

    @Test("backfills the agent-template columns onto an existing agent contact from member-profile metadata")
    func backfillsAgentContact() async throws {
        let dbManager = MockDatabaseManager.makeTestDatabase()
        let inboxId = "agent-inbox"
        let templateId = "tmpl-\(UUID().uuidString)"

        try await dbManager.dbWriter.write { db in
            try self.seedConversationAndMember(db: db, conversationId: "conv-1", inboxId: inboxId)
            try DBMemberProfile(
                conversationId: "conv-1",
                inboxId: inboxId,
                name: "King's Tutor",
                avatar: nil,
                metadata: [
                    "templateId": .string(templateId),
                    "publishedUrl": .string("https://example.com/t/abc"),
                    "emoji": .string("🦉"),
                ]
            ).save(db)
            // dev-era agent contact: verified, but the new templateId column is null.
            try DBContact(
                inboxId: inboxId,
                addedAt: Date(),
                addedViaConversationId: nil,
                displayName: "King's Tutor",
                agentVerification: .verified(.convos),
                agentTemplateId: nil
            ).insert(db)
        }

        try await runBackfill(dbManager)

        let contact = try await dbManager.dbReader.read { db in
            try self.fetchContact(db, inboxId)
        }
        #expect(contact?.agentTemplateId == templateId)
        #expect(contact?.agentTemplatePublishedURL == "https://example.com/t/abc")
        #expect(contact?.agentTemplateEmoji == "🦉")
        // The hydrated Contact now carries the templateId the visibility gate requires.
        #expect(contact.map(Contact.init(dbContact:))?.agentTemplateId == templateId)
    }

    @Test("leaves a human contact (no template metadata) untouched")
    func leavesHumanContact() async throws {
        let dbManager = MockDatabaseManager.makeTestDatabase()
        let inboxId = "human-inbox"

        try await dbManager.dbWriter.write { db in
            try self.seedConversationAndMember(db: db, conversationId: "conv-1", inboxId: inboxId)
            try DBMemberProfile(
                conversationId: "conv-1",
                inboxId: inboxId,
                name: "Alice",
                avatar: nil,
                metadata: nil
            ).save(db)
            try DBContact(
                inboxId: inboxId,
                addedAt: Date(),
                addedViaConversationId: nil,
                displayName: "Alice",
                agentVerification: nil,
                agentTemplateId: nil
            ).insert(db)
        }

        try await runBackfill(dbManager)

        let contact = try await dbManager.dbReader.read { db in
            try self.fetchContact(db, inboxId)
        }
        #expect(contact?.agentTemplateId == nil)
    }

    @Test("skips an empty/whitespace templateId and never clobbers an already-set one")
    func trimsAndDoesNotClobber() async throws {
        let dbManager = MockDatabaseManager.makeTestDatabase()

        try await dbManager.dbWriter.write { db in
            try self.seedConversationAndMember(db: db, conversationId: "conv-1", inboxId: "whitespace-inbox")
            try DBMember(inboxId: "set-inbox").save(db, onConflict: .ignore)

            // whitespace-only templateId must be treated as absent (mirrors trimmedMetadata)
            try DBMemberProfile(
                conversationId: "conv-1",
                inboxId: "whitespace-inbox",
                name: nil,
                avatar: nil,
                metadata: ["templateId": .string("   ")]
            ).save(db)
            try DBContact(
                inboxId: "whitespace-inbox",
                addedAt: Date(),
                addedViaConversationId: nil,
                agentVerification: .verified(.convos),
                agentTemplateId: nil
            ).insert(db)

            // a contact that already has a templateId must not be overwritten
            try DBMemberProfile(
                conversationId: "conv-1",
                inboxId: "set-inbox",
                name: nil,
                avatar: nil,
                metadata: ["templateId": .string("incoming")]
            ).save(db)
            try DBContact(
                inboxId: "set-inbox",
                addedAt: Date(),
                addedViaConversationId: nil,
                agentVerification: .verified(.convos),
                agentTemplateId: "original"
            ).insert(db)
        }

        try await runBackfill(dbManager)

        let (whitespace, alreadySet) = try await dbManager.dbReader.read { db in
            (try self.fetchContact(db, "whitespace-inbox"), try self.fetchContact(db, "set-inbox"))
        }
        #expect(whitespace?.agentTemplateId == nil)
        #expect(alreadySet?.agentTemplateId == "original")
    }
}
