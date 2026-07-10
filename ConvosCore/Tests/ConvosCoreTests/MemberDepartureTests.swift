@testable import ConvosCore
import Foundation
import GRDB
import Testing

/// Coverage for the pending-leave marker lifecycle: written when a
/// leave-request message is ingested (`IncomingMessageWriter.applyMemberDeparture`),
/// used by `ConversationWriter.reconcileMemberDepartures` to keep a leaver out
/// of the persisted member rows while the MLS roster still lists them, and
/// cleared when the removal finalizes or a membership add re-admits the inbox.
@Suite("Member departure marker Tests", .serialized)
struct MemberDepartureTests {
    private static let currentInboxId: String = "inbox-current"
    private static let leaverInboxId: String = "inbox-leaver"

    // MARK: - Seeding

    private static func seedConversation(db: Database, id: String) throws {
        try DBMember(inboxId: currentInboxId).save(db, onConflict: .ignore)
        try DBInbox(
            inboxId: currentInboxId,
            clientId: "client-current",
            createdAt: Date()
        ).save(db, onConflict: .ignore)
        try DBMember(inboxId: leaverInboxId).save(db, onConflict: .ignore)

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

        for inboxId in [currentInboxId, leaverInboxId] {
            try DBConversationMember(
                conversationId: id,
                inboxId: inboxId,
                role: .member,
                consent: .allowed,
                createdAt: Date(),
                invitedByInboxId: nil
            ).insert(db)
        }
    }

    private static func memberRow(db: Database, conversationId: String, inboxId: String) throws -> DBConversationMember? {
        try DBConversationMember
            .filter(DBConversationMember.Columns.conversationId == conversationId)
            .filter(DBConversationMember.Columns.inboxId == inboxId)
            .fetchOne(db)
    }

    private static func departureRows(db: Database, conversationId: String) throws -> [DBMemberDeparture] {
        try DBMemberDeparture
            .filter(DBMemberDeparture.Columns.conversationId == conversationId)
            .fetchAll(db)
    }

    /// Stores a membership-add update message, the shape a rejoin's
    /// GroupUpdated commit produces on ingest.
    private static func storeMembershipAdd(
        db: Database,
        conversationId: String,
        addedInboxId: String,
        dateNs: Int64
    ) throws {
        try DBMessage(
            id: "msg-add-\(dateNs)",
            clientMessageId: "msg-add-\(dateNs)",
            conversationId: conversationId,
            senderId: currentInboxId,
            dateNs: dateNs,
            date: Date(),
            sortId: dateNs,
            status: .published,
            messageType: .original,
            contentType: .update,
            text: nil,
            emoji: nil,
            invite: nil,
            linkPreview: nil,
            sourceMessageId: nil,
            attachmentUrls: [],
            update: DBMessage.Update(
                initiatedByInboxId: currentInboxId,
                addedInboxIds: [addedInboxId],
                removedInboxIds: [],
                metadataChanges: [],
                expiresAt: nil
            )
        ).insert(db)
    }

    // MARK: - applyMemberDeparture

    @Test("Departure drops the member row and records the marker")
    func testDepartureDropsMemberRowAndRecordsMarker() throws {
        let dbManager = MockDatabaseManager.makeTestDatabase()
        try dbManager.dbWriter.write { db in
            try Self.seedConversation(db: db, id: "convo")
            try IncomingMessageWriter.applyMemberDeparture(
                conversationId: "convo",
                inboxId: Self.leaverInboxId,
                dateNs: 1_000,
                in: db
            )
        }

        try dbManager.dbReader.read { db in
            let member = try Self.memberRow(db: db, conversationId: "convo", inboxId: Self.leaverInboxId)
            #expect(member == nil)
            let departures = try Self.departureRows(db: db, conversationId: "convo")
            #expect(departures.map(\.inboxId) == [Self.leaverInboxId])
            let remaining = try Self.memberRow(db: db, conversationId: "convo", inboxId: Self.currentInboxId)
            #expect(remaining != nil)
        }
    }

    @Test("Departure is idempotent across re-ingested leave requests")
    func testDepartureIsIdempotent() throws {
        let dbManager = MockDatabaseManager.makeTestDatabase()
        try dbManager.dbWriter.write { db in
            try Self.seedConversation(db: db, id: "convo")
            try IncomingMessageWriter.applyMemberDeparture(
                conversationId: "convo", inboxId: Self.leaverInboxId, dateNs: 1_000, in: db
            )
            try IncomingMessageWriter.applyMemberDeparture(
                conversationId: "convo", inboxId: Self.leaverInboxId, dateNs: 1_000, in: db
            )
        }

        try dbManager.dbReader.read { db in
            let departures = try Self.departureRows(db: db, conversationId: "convo")
            #expect(departures.count == 1)
        }
    }

    @Test("Stale leave-request after a stored rejoin-add is skipped")
    func testStaleLeaveAfterRejoinAddIsSkipped() throws {
        // Backlog catch-up processes newest-first: while this device was
        // offline the member left, the removal finalized, and they were
        // re-added. The rejoin-add (newer) is ingested before the old
        // leave-request; applying that stale leave would hide a current
        // member behind a marker nothing later clears.
        let dbManager = MockDatabaseManager.makeTestDatabase()
        let departed = try dbManager.dbWriter.write { db -> Set<String> in
            try Self.seedConversation(db: db, id: "convo")
            try Self.storeMembershipAdd(
                db: db,
                conversationId: "convo",
                addedInboxId: Self.leaverInboxId,
                dateNs: 2_000
            )
            try IncomingMessageWriter.applyMemberDeparture(
                conversationId: "convo", inboxId: Self.leaverInboxId, dateNs: 1_000, in: db
            )
            return try ConversationWriter.reconcileMemberDepartures(
                conversationId: "convo",
                mlsMemberInboxIds: [Self.currentInboxId, Self.leaverInboxId],
                in: db
            )
        }

        #expect(departed.isEmpty)
        try dbManager.dbReader.read { db in
            let member = try Self.memberRow(db: db, conversationId: "convo", inboxId: Self.leaverInboxId)
            #expect(member != nil)
            let departures = try Self.departureRows(db: db, conversationId: "convo")
            #expect(departures.isEmpty)
        }
    }

    @Test("Leave-request newer than a stored add still applies")
    func testLeaveNewerThanStoredAddStillApplies() throws {
        // The inverse ordering: the stored add predates the leave, so the
        // member really did leave after (re)joining and must be marked.
        let dbManager = MockDatabaseManager.makeTestDatabase()
        try dbManager.dbWriter.write { db in
            try Self.seedConversation(db: db, id: "convo")
            try Self.storeMembershipAdd(
                db: db,
                conversationId: "convo",
                addedInboxId: Self.leaverInboxId,
                dateNs: 1_000
            )
            try IncomingMessageWriter.applyMemberDeparture(
                conversationId: "convo", inboxId: Self.leaverInboxId, dateNs: 2_000, in: db
            )
        }

        try dbManager.dbReader.read { db in
            let member = try Self.memberRow(db: db, conversationId: "convo", inboxId: Self.leaverInboxId)
            #expect(member == nil)
            let departures = try Self.departureRows(db: db, conversationId: "convo")
            #expect(departures.map(\.inboxId) == [Self.leaverInboxId])
        }
    }

    // MARK: - clearMemberDepartures

    @Test("Membership add clears the marker for the re-added inbox only")
    func testAddClearsMarkerForReAddedInbox() throws {
        let dbManager = MockDatabaseManager.makeTestDatabase()
        try dbManager.dbWriter.write { db in
            try Self.seedConversation(db: db, id: "convo")
            try IncomingMessageWriter.applyMemberDeparture(
                conversationId: "convo", inboxId: Self.leaverInboxId, dateNs: 1_000, in: db
            )
            try IncomingMessageWriter.applyMemberDeparture(
                conversationId: "convo", inboxId: "inbox-other-leaver", dateNs: 1_100, in: db
            )
            try IncomingMessageWriter.clearMemberDepartures(
                conversationId: "convo",
                inboxIds: [Self.leaverInboxId],
                beforeNs: 5_000,
                in: db
            )
        }

        try dbManager.dbReader.read { db in
            let departures = try Self.departureRows(db: db, conversationId: "convo")
            #expect(departures.map(\.inboxId) == ["inbox-other-leaver"])
        }
    }

    @Test("An add older than the marker does not clear it")
    func testOlderAddKeepsNewerMarker() throws {
        // Newest-first backlog ordering can ingest an old add after a newer
        // leave. The leave happened last, so its marker must survive.
        let dbManager = MockDatabaseManager.makeTestDatabase()
        try dbManager.dbWriter.write { db in
            try Self.seedConversation(db: db, id: "convo")
            try IncomingMessageWriter.applyMemberDeparture(
                conversationId: "convo", inboxId: Self.leaverInboxId, dateNs: 3_000, in: db
            )
            try IncomingMessageWriter.clearMemberDepartures(
                conversationId: "convo",
                inboxIds: [Self.leaverInboxId],
                beforeNs: 1_000,
                in: db
            )
        }

        try dbManager.dbReader.read { db in
            let departures = try Self.departureRows(db: db, conversationId: "convo")
            #expect(departures.map(\.inboxId) == [Self.leaverInboxId])
        }
    }

    // MARK: - reconcileMemberDepartures

    @Test("Leaver still in the MLS roster stays excluded and keeps the marker")
    func testPendingLeaverStaysExcluded() throws {
        let dbManager = MockDatabaseManager.makeTestDatabase()
        let departed = try dbManager.dbWriter.write { db -> Set<String> in
            try Self.seedConversation(db: db, id: "convo")
            try IncomingMessageWriter.applyMemberDeparture(
                conversationId: "convo", inboxId: Self.leaverInboxId, dateNs: 1_000, in: db
            )
            // The remove-commit hasn't finalized: the synced roster still
            // lists the leaver.
            return try ConversationWriter.reconcileMemberDepartures(
                conversationId: "convo",
                mlsMemberInboxIds: [Self.currentInboxId, Self.leaverInboxId],
                in: db
            )
        }

        #expect(departed == [Self.leaverInboxId])
        try dbManager.dbReader.read { db in
            let departures = try Self.departureRows(db: db, conversationId: "convo")
            #expect(departures.count == 1)
        }
    }

    @Test("Finalized removal deletes the marker and returns no exclusions")
    func testFinalizedRemovalDeletesMarker() throws {
        let dbManager = MockDatabaseManager.makeTestDatabase()
        let departed = try dbManager.dbWriter.write { db -> Set<String> in
            try Self.seedConversation(db: db, id: "convo")
            try IncomingMessageWriter.applyMemberDeparture(
                conversationId: "convo", inboxId: Self.leaverInboxId, dateNs: 1_000, in: db
            )
            // The remove-commit finalized: the synced roster no longer lists
            // the leaver, so the marker has done its job.
            return try ConversationWriter.reconcileMemberDepartures(
                conversationId: "convo",
                mlsMemberInboxIds: [Self.currentInboxId],
                in: db
            )
        }

        #expect(departed.isEmpty)
        try dbManager.dbReader.read { db in
            let departures = try Self.departureRows(db: db, conversationId: "convo")
            #expect(departures.isEmpty)
        }
    }

    @Test("No markers means no exclusions")
    func testNoMarkersNoExclusions() throws {
        let dbManager = MockDatabaseManager.makeTestDatabase()
        let departed = try dbManager.dbWriter.write { db -> Set<String> in
            try Self.seedConversation(db: db, id: "convo")
            return try ConversationWriter.reconcileMemberDepartures(
                conversationId: "convo",
                mlsMemberInboxIds: [Self.currentInboxId, Self.leaverInboxId],
                in: db
            )
        }
        #expect(departed.isEmpty)
    }

    // MARK: - Creator departure

    @Test("Creator departure keeps the conversation visible in the detailed query")
    func testCreatorDepartureKeepsConversationVisible() throws {
        // The detailed conversation query joins the creator's member row.
        // When the creator self-leaves, the departure ingest deletes that row
        // on every other member's device; the join must be optional or the
        // conversation silently disappears from the list and detail views
        // (the user-visible "conversation was deleted" bug).
        let dbManager = MockDatabaseManager.makeTestDatabase()
        try dbManager.dbWriter.write { db in
            // seedConversation sets creatorId to currentInboxId; here the
            // leaver must be the creator, so seed with the creator flipped.
            try DBMember(inboxId: Self.currentInboxId).save(db, onConflict: .ignore)
            try DBInbox(
                inboxId: Self.currentInboxId,
                clientId: "client-current",
                createdAt: Date()
            ).save(db, onConflict: .ignore)
            try DBMember(inboxId: Self.leaverInboxId).save(db, onConflict: .ignore)
            try DBConversation(
                id: "convo",
                clientConversationId: "client-convo",
                inviteTag: "tag-convo",
                creatorId: Self.leaverInboxId,
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
                conversationId: "convo",
                isPinned: false,
                isUnread: false,
                isUnreadUpdatedAt: Date(),
                isMuted: false,
                pinnedOrder: nil,
                hidesInviteCard: false,
                leftHostedInviteSession: false,
                wasRemoved: false,
                hasHadOtherMembers: false,
                hasSharedInvite: false
            ).insert(db)
            for inboxId in [Self.currentInboxId, Self.leaverInboxId] {
                try DBConversationMember(
                    conversationId: "convo",
                    inboxId: inboxId,
                    role: inboxId == Self.leaverInboxId ? .superAdmin : .member,
                    consent: .allowed,
                    createdAt: Date(),
                    invitedByInboxId: nil
                ).insert(db)
                try DBMemberProfile(
                    conversationId: "convo",
                    inboxId: inboxId,
                    name: nil,
                    avatar: nil
                ).insert(db)
            }

            try IncomingMessageWriter.applyMemberDeparture(
                conversationId: "convo",
                inboxId: Self.leaverInboxId,
                dateNs: 1_000,
                in: db
            )
        }

        try dbManager.dbReader.read { db in
            let details = try DBConversation
                .filter(DBConversation.Columns.id == "convo")
                .detailedConversationQuery()
                .fetchOne(db)
            let hydrated = try #require(details?.hydrateConversation(currentInboxId: Self.currentInboxId))
            #expect(hydrated.creator.profile.inboxId == Self.leaverInboxId)
            #expect(!hydrated.creator.isCurrentUser)
            #expect(hydrated.members.map(\.profile.inboxId) == [Self.currentInboxId])
        }
    }
}
