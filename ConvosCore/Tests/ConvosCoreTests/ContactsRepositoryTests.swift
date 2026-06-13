@testable import ConvosCore
import Foundation
import GRDB
import Testing

@Suite("ContactsRepository Tests", .serialized)
struct ContactsRepositoryTests {
    @Test("fetchAll returns contacts sorted alphabetically by displayName")
    func testAlphabeticalSort() throws {
        let dbManager = MockDatabaseManager.makeTestDatabase()

        try dbManager.dbWriter.write { db in
            try DBContact(
                inboxId: "inbox-charlie",
                addedAt: Date(timeIntervalSince1970: 1),
                addedViaConversationId: nil,
                displayName: "Charlie"
            ).save(db)
            try DBContact(
                inboxId: "inbox-alice",
                addedAt: Date(timeIntervalSince1970: 2),
                addedViaConversationId: nil,
                displayName: "alice"
            ).save(db)
            try DBContact(
                inboxId: "inbox-bob",
                addedAt: Date(timeIntervalSince1970: 3),
                addedViaConversationId: nil,
                displayName: "Bob"
            ).save(db)
        }

        let repo = ContactsRepository(databaseReader: dbManager.dbReader)
        let contacts = try repo.fetchAll()

        #expect(contacts.map(\.inboxId) == ["inbox-alice", "inbox-bob", "inbox-charlie"])
    }

    @Test("isContact returns true only for inboxIds with a contact row")
    func testIsContactLookup() throws {
        let dbManager = MockDatabaseManager.makeTestDatabase()

        try dbManager.dbWriter.write { db in
            try DBContact(
                inboxId: "known",
                addedAt: Date(),
                addedViaConversationId: nil,
                displayName: "Known"
            ).save(db)
        }

        let repo = ContactsRepository(databaseReader: dbManager.dbReader)
        #expect(try repo.isContact(inboxId: "known") == true)
        #expect(try repo.isContact(inboxId: "stranger") == false)
    }

    @Test("isBlocked is false for unknown inboxIds and unblocked contacts, true for blocked contacts")
    func testIsBlockedLookup() throws {
        let dbManager = MockDatabaseManager.makeTestDatabase()

        try dbManager.dbWriter.write { db in
            try DBContact(
                inboxId: "unblocked",
                addedAt: Date(),
                addedViaConversationId: nil,
                displayName: "Unblocked"
            ).save(db)
            try DBContact(
                inboxId: "blocked",
                addedAt: Date(),
                addedViaConversationId: nil,
                displayName: "Blocked",
                blockedAt: Date()
            ).save(db)
        }

        let repo = ContactsRepository(databaseReader: dbManager.dbReader)
        #expect(try repo.isBlocked(inboxId: "blocked") == true)
        #expect(try repo.isBlocked(inboxId: "unblocked") == false)
        #expect(try repo.isBlocked(inboxId: "stranger") == false)
    }

    @Test("fetchAll includes blocked contacts so the browse list can offer an unblock affordance")
    func testFetchAllIncludesBlockedContacts() throws {
        let dbManager = MockDatabaseManager.makeTestDatabase()

        try dbManager.dbWriter.write { db in
            try DBContact(
                inboxId: "alice",
                addedAt: Date(),
                addedViaConversationId: nil,
                displayName: "Alice"
            ).save(db)
            try DBContact(
                inboxId: "bob",
                addedAt: Date(),
                addedViaConversationId: nil,
                displayName: "Bob",
                blockedAt: Date()
            ).save(db)
        }

        let repo = ContactsRepository(databaseReader: dbManager.dbReader)
        let contacts = try repo.fetchAll()

        #expect(contacts.map(\.inboxId) == ["alice", "bob"])
        let bob = contacts.first { $0.inboxId == "bob" }
        #expect(bob?.isBlocked == true)
        let alice = contacts.first { $0.inboxId == "alice" }
        #expect(alice?.isBlocked == false)
    }

    @Test("Contacts with nil displayName fall back to \"Somebody\" in the sort key")
    func testNilDisplayNameFallback() throws {
        let dbManager = MockDatabaseManager.makeTestDatabase()

        try dbManager.dbWriter.write { db in
            try DBContact(
                inboxId: "zzzzzzzz",
                addedAt: Date(),
                addedViaConversationId: nil,
                displayName: nil
            ).save(db)
            try DBContact(
                inboxId: "aaa",
                addedAt: Date(),
                addedViaConversationId: nil,
                displayName: "Mid"
            ).save(db)
        }

        let repo = ContactsRepository(databaseReader: dbManager.dbReader)
        let names = try repo.fetchAll().map(\.resolvedDisplayName)
        // The nil-name contact resolves to "Somebody", not its inboxId, so
        // it sorts by "Somebody" - after "Mid" by case-insensitive compare.
        #expect(names == ["Mid", "Somebody"])
    }

    @Test("Agent contacts with nil displayName fall back to \"Agent\"")
    func testNilDisplayNameAgentFallback() throws {
        // Verified-agent signal: badge would render; placeholder should
        // match the badge by reading "Agent" instead of "Somebody".
        let verifiedAgent = Contact.mock(
            displayName: nil,
            agentVerification: .verified(.convos)
        )
        #expect(verifiedAgent.resolvedDisplayName == "Agent")

        // Template-backed agent with no verification snapshot yet still
        // reads as an agent - covers the brief window where templateId has
        // mirrored from the member profile before verification propagates.
        let templateAgent = Contact.mock(
            displayName: nil,
            agentTemplateId: "tpl-1"
        )
        #expect(templateAgent.resolvedDisplayName == "Agent")

        // Unverified-but-known agent (we have an agentVerification of
        // .unverified) is still an agent; calling it "Somebody" reads as
        // a bug.
        let unverifiedAgent = Contact.mock(
            displayName: nil,
            agentVerification: .unverified
        )
        #expect(unverifiedAgent.resolvedDisplayName == "Agent")

        // Sanity: no agent signal at all still resolves to "Somebody".
        let unnamedHuman = Contact.mock(displayName: nil)
        #expect(unnamedHuman.resolvedDisplayName == "Somebody")
    }

    @Test("sourceConversations returns the convo name + kind for each id, drops missing ids")
    func testSourceConversationsBatched() throws {
        let dbManager = MockDatabaseManager.makeTestDatabase()
        let now = Date()

        try dbManager.dbWriter.write { db in
            try DBMember(inboxId: "current").save(db, onConflict: .ignore)
            try DBConversation(
                id: "convo-dm",
                clientConversationId: "client-convo-dm",
                inviteTag: "tag-convo-dm",
                creatorId: "current",
                kind: .dm,
                consent: .allowed,
                createdAt: now,
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
            try DBConversation(
                id: "convo-group",
                clientConversationId: "client-convo-group",
                inviteTag: "tag-convo-group",
                creatorId: "current",
                kind: .group,
                consent: .allowed,
                createdAt: now,
                name: "Trip Planning",
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
        }

        let repo = ContactsRepository(databaseReader: dbManager.dbReader)
        let sources = try repo.sourceConversations(forIds: [
            "convo-dm",
            "convo-group",
            "missing-convo"
        ])

        #expect(sources.count == 2)
        #expect(sources["convo-dm"]?.kind == .dm)
        #expect(sources["convo-dm"]?.name == nil)
        #expect(sources["convo-group"]?.kind == .group)
        #expect(sources["convo-group"]?.name == "Trip Planning")
        #expect(sources["missing-convo"] == nil)
    }

    @Test("sourceConversations is a no-op for an empty input set")
    func testSourceConversationsEmpty() throws {
        let dbManager = MockDatabaseManager.makeTestDatabase()
        let repo = ContactsRepository(databaseReader: dbManager.dbReader)

        let sources = try repo.sourceConversations(forIds: [])

        #expect(sources.isEmpty)
    }

    @Test("fetchAll collapses agent instances of one template into a single canonical row")
    func testAgentInstancesDedupedToCanonicalRow() throws {
        let dbManager = MockDatabaseManager.makeTestDatabase()

        try dbManager.dbWriter.write { db in
            try DBContact(
                inboxId: "agent-instance-1",
                addedAt: Date(timeIntervalSince1970: 1),
                addedViaConversationId: nil,
                displayName: "Trip Helper",
                agentVerification: .verified(.convos),
                agentTemplateId: "tmpl-trip",
                agentTemplateEmoji: "🧳"
            ).save(db)
            try DBContact(
                inboxId: "agent-instance-2",
                addedAt: Date(timeIntervalSince1970: 2),
                addedViaConversationId: nil,
                displayName: "Vacation Buddy",
                agentVerification: .verified(.convos),
                agentTemplateId: "tmpl-trip",
                agentTemplateEmoji: "🏖️"
            ).save(db)
            try DBContact(
                inboxId: "human",
                addedAt: Date(timeIntervalSince1970: 3),
                addedViaConversationId: nil,
                displayName: "Dana"
            ).save(db)
            try DBAgentTemplate(
                templateId: "tmpl-trip",
                agentName: "Travel Agent",
                emoji: "✈️",
                avatarURL: nil,
                publishedURL: "https://convos.org/a/travel",
                templateDescription: nil,
                slug: nil,
                fetchedAt: Date()
            ).save(db)
        }

        let repo = ContactsRepository(databaseReader: dbManager.dbReader)
        let contacts = try repo.fetchAll()

        let agents = contacts.filter { $0.agentTemplateId == "tmpl-trip" }
        #expect(agents.count == 1)
        // Canonical published identity overlays the per-instance profile.
        #expect(agents.first?.displayName == "Travel Agent")
        #expect(agents.first?.profileEmoji == "✈️")
        #expect(agents.first?.agentTemplatePublishedURL == "https://convos.org/a/travel")
        // Humans are never collapsed.
        #expect(contacts.contains { $0.inboxId == "human" })
    }

    @Test("fetchAll still collapses instances when the template cache is cold, keeping instance identity")
    func testAgentInstancesDedupedWithColdCache() throws {
        let dbManager = MockDatabaseManager.makeTestDatabase()

        try dbManager.dbWriter.write { db in
            try DBContact(
                inboxId: "agent-instance-1",
                addedAt: Date(timeIntervalSince1970: 1),
                addedViaConversationId: nil,
                displayName: "First Instance",
                agentVerification: .verified(.convos),
                agentTemplateId: "tmpl-uncached"
            ).save(db)
            try DBContact(
                inboxId: "agent-instance-2",
                addedAt: Date(timeIntervalSince1970: 2),
                addedViaConversationId: nil,
                displayName: "Second Instance",
                agentVerification: .verified(.convos),
                agentTemplateId: "tmpl-uncached"
            ).save(db)
        }

        let repo = ContactsRepository(databaseReader: dbManager.dbReader)
        let contacts = try repo.fetchAll()

        let agents = contacts.filter { $0.agentTemplateId == "tmpl-uncached" }
        #expect(agents.count == 1)
        // No cache row yet, so the representative keeps its instance name.
        #expect(agents.first?.displayName == "First Instance")
    }

    @Test("Dedup representative is the earliest-added instance, and a block on any instance blocks the canonical row")
    func testDedupDeterministicRepresentativeAndBlockOR() throws {
        let dbManager = MockDatabaseManager.makeTestDatabase()

        try dbManager.dbWriter.write { db in
            // Earliest-added instance is NOT blocked.
            try DBContact(
                inboxId: "agent-early",
                addedAt: Date(timeIntervalSince1970: 1),
                addedViaConversationId: nil,
                displayName: "Early",
                agentVerification: .verified(.convos),
                agentTemplateId: "tmpl-x"
            ).save(db)
            // A later instance IS blocked.
            try DBContact(
                inboxId: "agent-late",
                addedAt: Date(timeIntervalSince1970: 2),
                addedViaConversationId: nil,
                displayName: "Late",
                blockedAt: Date(),
                agentVerification: .verified(.convos),
                agentTemplateId: "tmpl-x"
            ).save(db)
        }

        let repo = ContactsRepository(databaseReader: dbManager.dbReader)
        let agents = try repo.fetchAll().filter { $0.agentTemplateId == "tmpl-x" }

        #expect(agents.count == 1)
        // Deterministic representative = earliest-added instance.
        #expect(agents.first?.inboxId == "agent-early")
        // A block on any instance blocks the collapsed canonical row, so
        // dedup can't hide a block.
        #expect(agents.first?.isBlocked == true)
    }

    @Test("A metadata-less profile update does not clear the contact's sticky agent-template identity")
    func testStickyAgentTemplateIdentitySurvivesMetadataLessUpdate() {
        let agent = DBContact(
            inboxId: "agent-1",
            addedAt: Date(timeIntervalSince1970: 1),
            addedViaConversationId: nil,
            displayName: "Old Name",
            agentVerification: .verified(.convos),
            agentTemplateId: "tmpl-keep",
            agentTemplatePublishedURL: "https://convos.org/a/x",
            agentTemplateEmoji: "🤖"
        )
        // The name-only ProfileUpdate `convos agent serve` publishes at startup
        // carries no metadata, so every template field is nil.
        let nameOnly = ContactProfileSnapshot(displayName: "New Name")
        let updated = agent.replacingProfileFields(with: nameOnly, at: Date(timeIntervalSince1970: 100))

        #expect(updated.displayName == "New Name")
        // Sticky template identity survives the metadata-less overwrite.
        #expect(updated.agentTemplateId == "tmpl-keep")
        #expect(updated.agentTemplatePublishedURL == "https://convos.org/a/x")
        #expect(updated.agentTemplateEmoji == "🤖")
        // agentVerification is wholesale-replaced (not sticky).
        #expect(updated.agentVerification == nil)
    }
}
