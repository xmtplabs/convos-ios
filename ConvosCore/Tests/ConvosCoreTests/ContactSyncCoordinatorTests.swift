@testable import ConvosCore
import Foundation
import GRDB
import Testing

@Suite("ContactSyncCoordinator Tests", .serialized)
struct ContactSyncCoordinatorTests {
    private static func seedConversation(
        db: Database,
        conversationId: String,
        creatorInboxId: String,
        memberInboxIds: [String],
        memberProfiles: [String: (name: String?, avatar: String?)] = [:]
    ) throws {
        try DBMember(inboxId: creatorInboxId).save(db, onConflict: .ignore)
        for inboxId in memberInboxIds {
            try DBMember(inboxId: inboxId).save(db, onConflict: .ignore)
        }

        try DBConversation(
            id: conversationId,
            clientConversationId: conversationId,
            inviteTag: "tag-\(conversationId)",
            creatorId: creatorInboxId,
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
            hasHadVerifiedAssistant: false
        ).insert(db)

        for inboxId in memberInboxIds {
            try DBConversationMember(
                conversationId: conversationId,
                inboxId: inboxId,
                role: .member,
                consent: .allowed,
                createdAt: Date(),
                invitedByInboxId: nil
            ).save(db)

            if let profile = memberProfiles[inboxId] {
                try DBMemberProfile(
                    conversationId: conversationId,
                    inboxId: inboxId,
                    name: profile.name,
                    avatar: profile.avatar
                ).save(db)
            }
        }
    }

    @Test("syncContacts pulls non-self members into contacts and writes a sync marker")
    func testSyncContactsHappyPath() async throws {
        let dbManager = MockDatabaseManager.makeTestDatabase()
        let selfInboxId = "self-inbox"
        let conversationId = "conv-1"

        try await dbManager.dbWriter.write { db in
            try DBInbox(inboxId: selfInboxId, clientId: "client").save(db)
            try Self.seedConversation(
                db: db,
                conversationId: conversationId,
                creatorInboxId: selfInboxId,
                memberInboxIds: [selfInboxId, "alice", "bob"],
                memberProfiles: [
                    "alice": (name: "Alice", avatar: "https://example.com/a.png"),
                    "bob": (name: "Bob", avatar: nil)
                ]
            )
        }

        let coordinator = ContactSyncCoordinator(
            databaseWriter: dbManager.dbWriter,
            databaseReader: dbManager.dbReader
        )
        try await coordinator.syncContactsOnFirstMessage(for: conversationId)

        let contacts: [DBContact] = try await dbManager.dbReader.read { db in
            try DBContact.fetchAll(db)
        }
        #expect(Set(contacts.map(\.inboxId)) == Set(["alice", "bob"]))
        let alice = contacts.first { $0.inboxId == "alice" }
        #expect(alice?.displayName == "Alice")
        #expect(alice?.avatarURL == "https://example.com/a.png")
        #expect(alice?.addedViaConversationId == conversationId)

        let marker = try await dbManager.dbReader.read { db in
            try DBConversationContactsSync.fetchOne(db, key: conversationId)
        }
        #expect(marker != nil)
    }

    @Test("syncContacts is idempotent — second call short-circuits and preserves addedAt")
    func testSyncContactsIdempotent() async throws {
        let dbManager = MockDatabaseManager.makeTestDatabase()
        let selfInboxId = "self-inbox"
        let conversationId = "conv-1"

        try await dbManager.dbWriter.write { db in
            try DBInbox(inboxId: selfInboxId, clientId: "client").save(db)
            try Self.seedConversation(
                db: db,
                conversationId: conversationId,
                creatorInboxId: selfInboxId,
                memberInboxIds: [selfInboxId, "alice"]
            )
        }

        let coordinator = ContactSyncCoordinator(
            databaseWriter: dbManager.dbWriter,
            databaseReader: dbManager.dbReader
        )
        try await coordinator.syncContactsOnFirstMessage(for: conversationId)

        let firstAddedAt = try await dbManager.dbReader.read { db in
            try DBContact.fetchOne(db, key: "alice")?.addedAt
        }

        try await Task.sleep(nanoseconds: 5_000_000)

        try await coordinator.syncContactsOnFirstMessage(for: conversationId)

        let secondAddedAt = try await dbManager.dbReader.read { db in
            try DBContact.fetchOne(db, key: "alice")?.addedAt
        }
        #expect(firstAddedAt == secondAddedAt)
    }

    @Test("force-rerun on never-synced conversation skips when local user is not the creator")
    func testForceRerunSkipsNeverSyncedConversation() async throws {
        let dbManager = MockDatabaseManager.makeTestDatabase()
        let selfInboxId = "self-inbox"
        let conversationId = "conv-1"

        try await dbManager.dbWriter.write { db in
            try DBInbox(inboxId: selfInboxId, clientId: "client").save(db)
            try Self.seedConversation(
                db: db,
                conversationId: conversationId,
                // Creator is someone else — the local user was invited.
                creatorInboxId: "other-inbox",
                memberInboxIds: ["other-inbox", selfInboxId, "alice"]
            )
        }

        let coordinator = ContactSyncCoordinator(
            databaseWriter: dbManager.dbWriter,
            databaseReader: dbManager.dbReader
        )
        try await coordinator.syncContactsAfterMembershipChange(for: conversationId)

        let contacts: [DBContact] = try await dbManager.dbReader.read { db in
            try DBContact.fetchAll(db)
        }
        #expect(contacts.isEmpty, "Action-gated rule must skip when local user is not the conversation creator")
    }

    @Test("force-rerun on never-synced conversation proceeds when local user is the creator")
    func testForceRerunProceedsForCreator() async throws {
        let dbManager = MockDatabaseManager.makeTestDatabase()
        let selfInboxId = "self-inbox"
        let conversationId = "conv-1"

        try await dbManager.dbWriter.write { db in
            try DBInbox(inboxId: selfInboxId, clientId: "client").save(db)
            try Self.seedConversation(
                db: db,
                conversationId: conversationId,
                // Local user created this group — bypass the action-gate.
                creatorInboxId: selfInboxId,
                memberInboxIds: [selfInboxId, "alice", "bob"]
            )
        }

        let coordinator = ContactSyncCoordinator(
            databaseWriter: dbManager.dbWriter,
            databaseReader: dbManager.dbReader
        )
        try await coordinator.syncContactsAfterMembershipChange(for: conversationId)

        let contactIds: Set<String> = try await dbManager.dbReader.read { db in
            Set(try DBContact.fetchAll(db).map(\.inboxId))
        }
        #expect(contactIds == Set(["alice", "bob"]), "Self-as-creator should bypass the action-gate")

        // Marker should also be written, so future first-message hooks
        // are no-ops on this conversation.
        #expect(try coordinator.hasSyncedContacts(for: conversationId) == true)
    }

    @Test("force-rerun on already-synced conversation pulls in newly added members")
    func testForceRerunPicksUpNewMembers() async throws {
        let dbManager = MockDatabaseManager.makeTestDatabase()
        let selfInboxId = "self-inbox"
        let conversationId = "conv-1"

        try await dbManager.dbWriter.write { db in
            try DBInbox(inboxId: selfInboxId, clientId: "client").save(db)
            try Self.seedConversation(
                db: db,
                conversationId: conversationId,
                creatorInboxId: selfInboxId,
                memberInboxIds: [selfInboxId, "alice"]
            )
        }

        let coordinator = ContactSyncCoordinator(
            databaseWriter: dbManager.dbWriter,
            databaseReader: dbManager.dbReader
        )
        try await coordinator.syncContactsOnFirstMessage(for: conversationId)

        // Add a new member after the initial sync.
        try await dbManager.dbWriter.write { db in
            try DBMember(inboxId: "carol").save(db, onConflict: .ignore)
            try DBConversationMember(
                conversationId: conversationId,
                inboxId: "carol",
                role: .member,
                consent: .allowed,
                createdAt: Date(),
                invitedByInboxId: nil
            ).save(db)
        }

        try await coordinator.syncContactsAfterMembershipChange(for: conversationId)

        let contactIds: Set<String> = try await dbManager.dbReader.read { db in
            Set(try DBContact.fetchAll(db).map(\.inboxId))
        }
        #expect(contactIds == Set(["alice", "carol"]))
    }

    @Test("self inbox is excluded from contacts")
    func testSelfSkip() async throws {
        let dbManager = MockDatabaseManager.makeTestDatabase()
        let selfInboxId = "self-inbox"
        let conversationId = "conv-1"

        try await dbManager.dbWriter.write { db in
            try DBInbox(inboxId: selfInboxId, clientId: "client").save(db)
            try Self.seedConversation(
                db: db,
                conversationId: conversationId,
                creatorInboxId: selfInboxId,
                memberInboxIds: [selfInboxId, "alice"]
            )
        }

        let coordinator = ContactSyncCoordinator(
            databaseWriter: dbManager.dbWriter,
            databaseReader: dbManager.dbReader
        )
        try await coordinator.syncContactsOnFirstMessage(for: conversationId)

        let inboxIds: [String] = try await dbManager.dbReader.read { db in
            try DBContact.fetchAll(db).map(\.inboxId)
        }
        #expect(!inboxIds.contains(selfInboxId))
    }

    @Test("syncContacts no-ops when selfInboxIdProvider returns nil (across both pre-fix-broken quadrants)")
    func testSyncContactsNoOpsWhenSelfUnknown() async throws {
        let dbManager = MockDatabaseManager.makeTestDatabase()
        let selfInboxId = "self-inbox"
        let conversationId = "conv-1"

        // Seed a conversation but deliberately omit the DBInbox row so the
        // default selfInboxIdProvider would return nil. We also pass an
        // explicit nil-returning provider here to make the contract explicit.
        try await dbManager.dbWriter.write { db in
            try Self.seedConversation(
                db: db,
                conversationId: conversationId,
                creatorInboxId: selfInboxId,
                memberInboxIds: [selfInboxId, "alice", "bob"]
            )
        }

        let coordinator = ContactSyncCoordinator(
            databaseWriter: dbManager.dbWriter,
            databaseReader: dbManager.dbReader,
            selfInboxIdProvider: { _ in nil }
        )

        // Quadrant 1: first-message hook on never-synced (force=false). Pre-fix
        // this fell through both short-circuits and upserted every member,
        // including the local user, because the per-iteration self-skip guard
        // can't fire when self is nil.
        try await coordinator.syncContactsOnFirstMessage(for: conversationId)

        var contactIds: Set<String> = try await dbManager.dbReader.read { db in
            Set(try DBContact.fetchAll(db).map(\.inboxId))
        }
        #expect(contactIds.isEmpty, "Sync must no-op when self is unknown — no contacts should be written")
        #expect(try coordinator.hasSyncedContacts(for: conversationId) == false, "No marker should be written when self is unknown")

        // Seed a marker so the next call hits the (alreadySynced=true,
        // force=true) quadrant — the other path that was previously broken.
        try await dbManager.dbWriter.write { db in
            try DBConversationContactsSync(
                conversationId: conversationId,
                contactsSyncedAt: Date()
            ).save(db)
        }

        // Quadrant 2: member-added hook on already-synced. Pre-fix this fell
        // through both short-circuits the same way.
        try await coordinator.syncContactsAfterMembershipChange(for: conversationId)

        contactIds = try await dbManager.dbReader.read { db in
            Set(try DBContact.fetchAll(db).map(\.inboxId))
        }
        #expect(contactIds.isEmpty, "Forced sync must also no-op when self is unknown")
    }

    @Test("hasSyncedContacts mirrors marker presence")
    func testHasSyncedContacts() async throws {
        let dbManager = MockDatabaseManager.makeTestDatabase()
        let selfInboxId = "self-inbox"
        let conversationId = "conv-1"

        try await dbManager.dbWriter.write { db in
            try DBInbox(inboxId: selfInboxId, clientId: "client").save(db)
            try Self.seedConversation(
                db: db,
                conversationId: conversationId,
                creatorInboxId: selfInboxId,
                memberInboxIds: [selfInboxId, "alice"]
            )
        }

        let coordinator = ContactSyncCoordinator(
            databaseWriter: dbManager.dbWriter,
            databaseReader: dbManager.dbReader
        )
        #expect(try coordinator.hasSyncedContacts(for: conversationId) == false)
        try await coordinator.syncContactsOnFirstMessage(for: conversationId)
        #expect(try coordinator.hasSyncedContacts(for: conversationId) == true)
    }

    @Test("syncContacts skips the marker when only self is present so a later sync can retry")
    func testEmptyRosterDefersMarker() async throws {
        let dbManager = MockDatabaseManager.makeTestDatabase()
        let selfInboxId = "self-inbox"
        let conversationId = "conv-1"

        // Initial state: peer rows have not yet streamed in — only self is
        // a member. This mirrors the race we saw in the field where the
        // first-message hook fires before the StreamProcessor commits the
        // peer's `conversation_members` row.
        try await dbManager.dbWriter.write { db in
            try DBInbox(inboxId: selfInboxId, clientId: "client").save(db)
            try Self.seedConversation(
                db: db,
                conversationId: conversationId,
                creatorInboxId: selfInboxId,
                memberInboxIds: [selfInboxId]
            )
        }

        let coordinator = ContactSyncCoordinator(
            databaseWriter: dbManager.dbWriter,
            databaseReader: dbManager.dbReader
        )
        try await coordinator.syncContactsOnFirstMessage(for: conversationId)

        // No contacts and no marker — we deliberately deferred so the next
        // outbound message gets another chance.
        #expect(try coordinator.hasSyncedContacts(for: conversationId) == false)
        let count = try await dbManager.dbReader.read { db in
            try DBContact.fetchCount(db)
        }
        #expect(count == 0)

        // Peer arrives.
        try await dbManager.dbWriter.write { db in
            try DBMember(inboxId: "alice").save(db, onConflict: .ignore)
            try DBConversationMember(
                conversationId: conversationId,
                inboxId: "alice",
                role: .member,
                consent: .allowed,
                createdAt: Date(),
                invitedByInboxId: nil
            ).save(db)
        }

        // Next sync (e.g. from the next outbound message) lands the contact
        // and writes the marker.
        try await coordinator.syncContactsOnFirstMessage(for: conversationId)
        #expect(try coordinator.hasSyncedContacts(for: conversationId) == true)
        let inboxIds: Set<String> = try await dbManager.dbReader.read { db in
            Set(try DBContact.fetchAll(db).map(\.inboxId))
        }
        #expect(inboxIds == Set(["alice"]))
    }

    // MARK: - Agent template capture

    /// Saves a template-backed verified-agent member profile: `memberKind`
    /// is `.verifiedConvos` and the metadata carries the `templateId` plus
    /// the published-template fields the agent runtime stamps.
    private static func saveAgentProfile(
        db: Database,
        conversationId: String,
        inboxId: String,
        templateId: String,
        name: String = "Tifoso",
        emoji: String = "🚴",
        descriptionText: String = "Pro cycling expert",
        publishedUrl: String = "https://agents-dev.convos.org/tifoso.pnw1o"
    ) throws {
        try DBMemberProfile(
            conversationId: conversationId,
            inboxId: inboxId,
            name: name,
            avatar: nil,
            memberKind: .verifiedConvos,
            metadata: [
                "templateId": .string(templateId),
                "emoji": .string(emoji),
                "description": .string(descriptionText),
                "publishedUrl": .string(publishedUrl)
            ]
        ).save(db)
    }

    @Test("A conversation with a template-backed agent captures the template as a contact")
    func testTemplateBackedAgentCapturedAsContact() async throws {
        let dbManager = MockDatabaseManager.makeTestDatabase()
        let selfInboxId = "self-inbox"
        let conversationId = "conv-1"
        let templateId = "200e27dc-badc-429f-a431-b01b0281ec95"

        try await dbManager.dbWriter.write { db in
            try DBInbox(inboxId: selfInboxId, clientId: "client").save(db)
            try Self.seedConversation(
                db: db,
                conversationId: conversationId,
                creatorInboxId: selfInboxId,
                memberInboxIds: [selfInboxId, "agent-instance-a"]
            )
            try Self.saveAgentProfile(
                db: db,
                conversationId: conversationId,
                inboxId: "agent-instance-a",
                templateId: templateId
            )
        }

        let coordinator = ContactSyncCoordinator(
            databaseWriter: dbManager.dbWriter,
            databaseReader: dbManager.dbReader
        )
        try await coordinator.syncContactsOnFirstMessage(for: conversationId)

        let templateContacts = try await dbManager.dbReader.read { db in
            try DBAgentTemplateContact.fetchAll(db)
        }
        #expect(templateContacts.count == 1)
        let stored = templateContacts.first
        #expect(stored?.templateId == templateId)
        #expect(stored?.displayName == "Tifoso")
        #expect(stored?.emoji == "🚴")
        #expect(stored?.publishedURL == "https://agents-dev.convos.org/tifoso.pnw1o")
        #expect(stored?.addedViaConversationId == conversationId)
    }

    @Test("The same template across two conversations yields exactly one contact row")
    func testSameTemplateAcrossConversationsYieldsOneRow() async throws {
        let dbManager = MockDatabaseManager.makeTestDatabase()
        let selfInboxId = "self-inbox"
        let templateId = "200e27dc-badc-429f-a431-b01b0281ec95"

        try await dbManager.dbWriter.write { db in
            try DBInbox(inboxId: selfInboxId, clientId: "client").save(db)
            // Two conversations, two different agent instances (distinct
            // inboxIds), both provisioned from the same template.
            try Self.seedConversation(
                db: db,
                conversationId: "conv-1",
                creatorInboxId: selfInboxId,
                memberInboxIds: [selfInboxId, "agent-a"]
            )
            try Self.saveAgentProfile(
                db: db,
                conversationId: "conv-1",
                inboxId: "agent-a",
                templateId: templateId
            )
            try Self.seedConversation(
                db: db,
                conversationId: "conv-2",
                creatorInboxId: selfInboxId,
                memberInboxIds: [selfInboxId, "agent-b"]
            )
            try Self.saveAgentProfile(
                db: db,
                conversationId: "conv-2",
                inboxId: "agent-b",
                templateId: templateId
            )
        }

        let coordinator = ContactSyncCoordinator(
            databaseWriter: dbManager.dbWriter,
            databaseReader: dbManager.dbReader
        )
        try await coordinator.syncContactsOnFirstMessage(for: "conv-1")
        try await coordinator.syncContactsOnFirstMessage(for: "conv-2")

        let templateContacts = try await dbManager.dbReader.read { db in
            try DBAgentTemplateContact.fetchAll(db)
        }
        #expect(templateContacts.count == 1)
        #expect(templateContacts.first?.templateId == templateId)
    }

    @Test("A conversation with only humans and legacy verified agents yields no template contacts")
    func testNoTemplateContactsForHumansAndLegacyAgents() async throws {
        let dbManager = MockDatabaseManager.makeTestDatabase()
        let selfInboxId = "self-inbox"
        let conversationId = "conv-1"

        try await dbManager.dbWriter.write { db in
            try DBInbox(inboxId: selfInboxId, clientId: "client").save(db)
            try Self.seedConversation(
                db: db,
                conversationId: conversationId,
                creatorInboxId: selfInboxId,
                memberInboxIds: [selfInboxId, "alice", "legacy-agent"],
                memberProfiles: ["alice": (name: "Alice", avatar: nil)]
            )
            // A legacy verified agent: verified, but carries no templateId
            // in its profile metadata.
            try DBMemberProfile(
                conversationId: conversationId,
                inboxId: "legacy-agent",
                name: "Convos Assistant",
                avatar: nil,
                memberKind: .verifiedConvos,
                metadata: nil
            ).save(db)
        }

        let coordinator = ContactSyncCoordinator(
            databaseWriter: dbManager.dbWriter,
            databaseReader: dbManager.dbReader
        )
        try await coordinator.syncContactsOnFirstMessage(for: conversationId)

        let templateCount = try await dbManager.dbReader.read { db in
            try DBAgentTemplateContact.fetchCount(db)
        }
        #expect(templateCount == 0)

        // The inboxId-keyed contact table is unaffected: both non-self
        // members still land there (the legacy agent is hidden from the
        // browse list separately, by the `!isVerifiedAgent` filter).
        let contactIds: Set<String> = try await dbManager.dbReader.read { db in
            Set(try DBContact.fetchAll(db).map(\.inboxId))
        }
        #expect(contactIds == Set(["alice", "legacy-agent"]))
    }
}
