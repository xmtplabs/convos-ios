@testable import ConvosCore
import Foundation
import GRDB
import Testing

/// Coverage for the persisted removed-from-conversation marker: set by
/// `IncomingMessageWriter.persistRemovedMarker` when a GroupUpdated removal
/// names the local inbox, cleared by
/// `ConversationWriter.clearRemovedMarkerIfMember` when a synced member list
/// proves membership again, and filtered out of the conversations list
/// queries. Regression coverage for the 2026-06-04 incident where removal was
/// only hidden in-memory and a relaunch resurrected a dead conversation.
@Suite("Conversation removed-state Tests", .serialized)
struct ConversationRemovedStateTests {
    private static let currentInboxId: String = "inbox-current"
    private static let otherInboxId: String = "inbox-other"

    // MARK: - Seeding

    private static func seedInbox(db: Database) throws {
        try DBMember(inboxId: currentInboxId).save(db, onConflict: .ignore)
        try DBInbox(
            inboxId: currentInboxId,
            clientId: "client-current",
            createdAt: Date()
        ).save(db, onConflict: .ignore)
    }

    private static func seedConversation(
        db: Database,
        id: String,
        isPinned: Bool = false,
        wasRemoved: Bool = false
    ) throws {
        try seedInbox(db: db)
        try DBMember(inboxId: otherInboxId).save(db, onConflict: .ignore)

        try DBConversation(
            id: id,
            clientConversationId: "client-\(id)",
            inviteTag: "tag-\(id)",
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
            hasHadVerifiedAgent: false
        ).insert(db)

        try ConversationLocalState(
            conversationId: id,
            isPinned: isPinned,
            isUnread: false,
            isUnreadUpdatedAt: Date(),
            isMuted: false,
            pinnedOrder: isPinned ? 1 : nil,
            hidesInviteCard: false,
            leftHostedInviteSession: false,
            wasRemoved: wasRemoved,
            hasHadOtherMembers: false,
            hasSharedInvite: false
        ).insert(db)

        for inboxId in [currentInboxId, otherInboxId] {
            try DBConversationMember(
                conversationId: id,
                inboxId: inboxId,
                role: inboxId == currentInboxId ? .superAdmin : .member,
                consent: .allowed,
                createdAt: Date(),
                invitedByInboxId: nil
            ).insert(db)
            try DBMemberProfile(
                conversationId: id,
                inboxId: inboxId,
                name: inboxId,
                avatar: nil
            ).insert(db, onConflict: .ignore)
        }
    }

    private static func localState(db: Database, id: String) throws -> ConversationLocalState? {
        try ConversationLocalState
            .filter(ConversationLocalState.Columns.conversationId == id)
            .fetchOne(db)
    }

    // MARK: - isRemovedFromConversation

    private static func membershipUpdate(
        initiatedBy: String,
        removed: [String]
    ) -> DBMessage.Update {
        DBMessage.Update(
            initiatedByInboxId: initiatedBy,
            addedInboxIds: [],
            removedInboxIds: removed,
            metadataChanges: [],
            expiresAt: nil
        )
    }

    @Test("Admin removal naming the local inbox is processed as a removal")
    func testAdminRemovalIsProcessed() throws {
        let removed = IncomingMessageWriter.isRemovedFromConversation(
            update: Self.membershipUpdate(initiatedBy: Self.otherInboxId, removed: [Self.currentInboxId]),
            localInboxId: Self.currentInboxId,
            conversationConsent: .allowed
        )
        #expect(removed)
    }

    @Test("Self-leave echo on a sibling installation (consent still allowed) is processed as a removal")
    func testSelfLeaveEchoOnSiblingInstallationIsProcessed() throws {
        // Device pairing puts the same inbox on multiple installations. The
        // sibling never ran the local leave flow, and the finalization commit
        // is not mapped for self-leaves, so the echo must set the marker or
        // the conversation stays visible until consent sync converges.
        let removed = IncomingMessageWriter.isRemovedFromConversation(
            update: Self.membershipUpdate(initiatedBy: Self.currentInboxId, removed: [Self.currentInboxId]),
            localInboxId: Self.currentInboxId,
            conversationConsent: .allowed
        )
        #expect(removed)
    }

    @Test("Self-leave echo on the initiating installation (consent already denied) stays skipped")
    func testSelfLeaveEchoOnInitiatorIsSkipped() throws {
        // The leave flow already hid the conversation via the consent path;
        // the echo must not re-mark it.
        let removed = IncomingMessageWriter.isRemovedFromConversation(
            update: Self.membershipUpdate(initiatedBy: Self.currentInboxId, removed: [Self.currentInboxId]),
            localInboxId: Self.currentInboxId,
            conversationConsent: .denied
        )
        #expect(!removed)
    }

    @Test("Updates that do not remove the local inbox never mark a removal")
    func testUnrelatedUpdateIsIgnored() throws {
        let removed = IncomingMessageWriter.isRemovedFromConversation(
            update: Self.membershipUpdate(initiatedBy: Self.otherInboxId, removed: [Self.otherInboxId]),
            localInboxId: Self.currentInboxId,
            conversationConsent: .allowed
        )
        #expect(!removed)
        let noUpdate = IncomingMessageWriter.isRemovedFromConversation(
            update: nil,
            localInboxId: Self.currentInboxId,
            conversationConsent: .allowed
        )
        #expect(!noUpdate)
        let noInbox = IncomingMessageWriter.isRemovedFromConversation(
            update: Self.membershipUpdate(initiatedBy: Self.otherInboxId, removed: [Self.currentInboxId]),
            localInboxId: nil,
            conversationConsent: .allowed
        )
        #expect(!noInbox)
    }

    // MARK: - persistRemovedMarker

    @Test("Marks the conversation removed and unpins it")
    func testMarkerSetsFlagAndUnpins() throws {
        let dbManager = MockDatabaseManager.makeTestDatabase()
        try dbManager.dbWriter.write { db in
            try Self.seedConversation(db: db, id: "convo", isPinned: true)
            try IncomingMessageWriter.persistRemovedMarker(conversationId: "convo", in: db)
        }

        let state = try dbManager.dbReader.read { db in
            try Self.localState(db: db, id: "convo")
        }
        #expect(state?.wasRemoved == true)
        #expect(state?.isPinned == false)
        #expect(state?.pinnedOrder == nil)
    }

    @Test("Marker is idempotent across repeated removal messages")
    func testMarkerIsIdempotent() throws {
        let dbManager = MockDatabaseManager.makeTestDatabase()
        try dbManager.dbWriter.write { db in
            try Self.seedConversation(db: db, id: "convo")
            try IncomingMessageWriter.persistRemovedMarker(conversationId: "convo", in: db)
            try IncomingMessageWriter.persistRemovedMarker(conversationId: "convo", in: db)
        }

        let state = try dbManager.dbReader.read { db in
            try Self.localState(db: db, id: "convo")
        }
        #expect(state?.wasRemoved == true)
    }

    @Test("Marker creates a local-state row when none exists yet")
    func testMarkerCreatesMissingRow() throws {
        let dbManager = MockDatabaseManager.makeTestDatabase()
        try dbManager.dbWriter.write { db in
            try Self.seedConversation(db: db, id: "convo")
            try ConversationLocalState
                .filter(ConversationLocalState.Columns.conversationId == "convo")
                .deleteAll(db)
            try IncomingMessageWriter.persistRemovedMarker(conversationId: "convo", in: db)
        }

        let state = try dbManager.dbReader.read { db in
            try Self.localState(db: db, id: "convo")
        }
        #expect(state?.wasRemoved == true)
    }

    // MARK: - clearRemovedMarkerIfMember

    @Test("Clears the marker when the synced member list includes the local inbox")
    func testClearOnRenewedMembership() throws {
        let dbManager = MockDatabaseManager.makeTestDatabase()
        try dbManager.dbWriter.write { db in
            try Self.seedConversation(db: db, id: "convo", wasRemoved: true)
            try ConversationWriter.clearRemovedMarkerIfMember(
                conversationId: "convo",
                currentMemberInboxIds: [Self.currentInboxId, Self.otherInboxId],
                in: db
            )
        }

        let state = try dbManager.dbReader.read { db in
            try Self.localState(db: db, id: "convo")
        }
        #expect(state?.wasRemoved == false)
    }

    @Test("Stream echoes without the local inbox leave the marker alone")
    func testNoClearWithoutMembership() throws {
        let dbManager = MockDatabaseManager.makeTestDatabase()
        try dbManager.dbWriter.write { db in
            try Self.seedConversation(db: db, id: "convo", wasRemoved: true)
            try ConversationWriter.clearRemovedMarkerIfMember(
                conversationId: "convo",
                currentMemberInboxIds: [Self.otherInboxId],
                in: db
            )
        }

        let state = try dbManager.dbReader.read { db in
            try Self.localState(db: db, id: "convo")
        }
        #expect(state?.wasRemoved == true)
    }

    // MARK: - List filtering

    @Test("fetchAll excludes removed conversations and keeps the rest")
    func testFetchAllExcludesRemoved() throws {
        let dbManager = MockDatabaseManager.makeTestDatabase()
        try dbManager.dbWriter.write { db in
            try Self.seedConversation(db: db, id: "convo-live")
            try Self.seedConversation(db: db, id: "convo-removed", wasRemoved: true)
        }

        let repo = ConversationsRepository(dbReader: dbManager.dbReader, consent: [.allowed])
        let conversations = try repo.fetchAll()

        #expect(conversations.contains { $0.id == "convo-live" })
        #expect(!conversations.contains { $0.id == "convo-removed" })
    }

    @Test("conversationsCount excludes removed conversations, matching the visible list")
    func testCountExcludesRemoved() throws {
        let dbManager = MockDatabaseManager.makeTestDatabase()
        try dbManager.dbWriter.write { db in
            try Self.seedConversation(db: db, id: "convo-live")
            try Self.seedConversation(db: db, id: "convo-removed", wasRemoved: true)
        }

        let countRepo = ConversationsCountRepository(databaseReader: dbManager.dbReader, consent: [.allowed])
        #expect(try countRepo.fetchCount() == 1)
    }

    @Test("findOneToOne does not resurface a removed 1:1")
    func testFindOneToOneExcludesRemoved() throws {
        let dbManager = MockDatabaseManager.makeTestDatabase()
        try dbManager.dbWriter.write { db in
            try Self.seedConversation(db: db, id: "convo-removed", wasRemoved: true)
        }

        let repo = ConversationsRepository(dbReader: dbManager.dbReader, consent: [.allowed])
        let match = try repo.findOneToOne(with: Self.otherInboxId, excluding: nil)

        #expect(match == nil)
    }

    // MARK: - Single-conversation hydration

    @Test("Single-conversation lookup still returns a removed conversation, surfaced as wasRemoved")
    func testSingleLookupSurfacesWasRemoved() throws {
        let dbManager = MockDatabaseManager.makeTestDatabase()
        try dbManager.dbWriter.write { db in
            try Self.seedConversation(db: db, id: "convo-removed", wasRemoved: true)
        }

        let conversation = try dbManager.dbReader.read { db in
            try DBConversation
                .filter(DBConversation.Columns.id == "convo-removed")
                .detailedConversationQuery()
                .fetchOne(db)?
                .hydrateConversation(currentInboxId: Self.currentInboxId)
        }

        #expect(conversation != nil)
        #expect(conversation?.wasRemoved == true)
    }
}
