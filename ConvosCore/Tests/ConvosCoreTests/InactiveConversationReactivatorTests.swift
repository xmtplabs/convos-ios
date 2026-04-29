@testable import ConvosCore
import Foundation
import GRDB
import Testing

/// DB-level contract for the reactivation flow extracted from
/// `StreamProcessor`. Verifies the state transitions the UI depends on:
///
/// - Inactive conversation + incoming message → `isActive` flips to true,
///   arriving update gets `isReconnection = true`, recent updates are
///   back-filled up to the configured limit.
/// - Active conversation + incoming message → no-op.
/// - The backfill limit is honored (older rows are left alone).
/// - The helper is idempotent (rows already flagged stay flagged, no churn).
@Suite("InactiveConversationReactivator")
struct InactiveConversationReactivatorTests {
    @Test("no-op when conversation is already active")
    func testNoOpWhenActive() async throws {
        let fixtures = TestFixtures()
        let reactivator = makeReactivator(fixtures: fixtures)
        let conversationId = try await seedConversation(in: fixtures, id: "conv-active", isActive: true)
        let messageId = try await seedUpdateMessage(
            in: fixtures, id: "msg-1", conversationId: conversationId, date: Date()
        )

        await reactivator.markReconnectionIfNeeded(
            messageId: messageId, conversationId: conversationId
        )

        let state = try await fetchLocalState(in: fixtures, conversationId: conversationId)
        let message = try await fetchMessage(in: fixtures, id: messageId)
        #expect(state?.isActive == true)
        #expect(message?.update?.isReconnection == false, "already-active path must not tag the message")

        try? await fixtures.cleanup()
    }

    @Test("flips isActive, tags arriving message, backfills recent updates")
    func testReactivationBackfill() async throws {
        let fixtures = TestFixtures()
        let reactivator = makeReactivator(fixtures: fixtures)
        let conversationId = try await seedConversation(in: fixtures, id: "conv-inactive", isActive: false)

        // Seed 6 historical update-type messages + 1 arriving message.
        // The backfill query takes the 5 most recent update rows by date
        // DESC — which is the arriving message + 4 historical (hist-5,
        // hist-4, hist-3, hist-2). The arriving message is also flagged
        // directly by `markReconnectionIfNeeded` before backfill runs.
        let now = Date()
        let historicalIds = (0 ..< 6).map { "hist-\($0)" }
        for (index, id) in historicalIds.enumerated() {
            let date = now.addingTimeInterval(-Double(historicalIds.count - index) * 60)
            _ = try await seedUpdateMessage(
                in: fixtures, id: id, conversationId: conversationId, date: date
            )
        }
        let arrivingId = try await seedUpdateMessage(
            in: fixtures, id: "arriving", conversationId: conversationId, date: now
        )

        await reactivator.markReconnectionIfNeeded(
            messageId: arrivingId, conversationId: conversationId
        )

        let state = try await fetchLocalState(in: fixtures, conversationId: conversationId)
        #expect(state?.isActive == true)

        let arriving = try await fetchMessage(in: fixtures, id: arrivingId)
        #expect(arriving?.update?.isReconnection == true)

        // Backfill window is 5 rows by date DESC. With the arriving row
        // consuming one slot, 4 historical rows get flagged: hist-2…hist-5.
        for id in ["hist-2", "hist-3", "hist-4", "hist-5"] {
            let message = try await fetchMessage(in: fixtures, id: id)
            #expect(message?.update?.isReconnection == true, "\(id) should be flagged")
        }
        for id in ["hist-0", "hist-1"] {
            let message = try await fetchMessage(in: fixtures, id: id)
            #expect(message?.update?.isReconnection == false, "\(id) should NOT be flagged")
        }

        try? await fixtures.cleanup()
    }

    @Test("arriving message without an Update is still enough to reactivate")
    func testReactivationWithoutUpdatePayload() async throws {
        let fixtures = TestFixtures()
        let reactivator = makeReactivator(fixtures: fixtures)
        let conversationId = try await seedConversation(in: fixtures, id: "conv-text", isActive: false)
        let textMessageId = try await seedTextMessage(
            in: fixtures, id: "text-1", conversationId: conversationId, date: Date()
        )

        await reactivator.markReconnectionIfNeeded(
            messageId: textMessageId, conversationId: conversationId
        )

        let state = try await fetchLocalState(in: fixtures, conversationId: conversationId)
        #expect(state?.isActive == true)

        try? await fixtures.cleanup()
    }

    @Test("backfill is idempotent — second run doesn't re-flag or churn")
    func testIdempotent() async throws {
        let fixtures = TestFixtures()
        let reactivator = makeReactivator(fixtures: fixtures)
        let conversationId = try await seedConversation(in: fixtures, id: "conv-idem", isActive: false)
        let messageId = try await seedUpdateMessage(
            in: fixtures, id: "only-update", conversationId: conversationId, date: Date()
        )

        await reactivator.markReconnectionIfNeeded(
            messageId: messageId, conversationId: conversationId
        )
        // Manually re-flip inactive to simulate a hypothetical second pass
        // over the same conversation — the backfill path should remain
        // correct without mutating already-flagged rows.
        try await fixtures.databaseManager.dbWriter.write { db in
            var state = try ConversationLocalState.fetchOne(db, key: conversationId)
            state = state?.with(isActive: false)
            try state?.save(db)
        }

        await reactivator.markReconnectionIfNeeded(
            messageId: messageId, conversationId: conversationId
        )

        let message = try await fetchMessage(in: fixtures, id: messageId)
        #expect(message?.update?.isReconnection == true)

        try? await fixtures.cleanup()
    }

    @Test("backfill limit matches the published constant")
    func testBackfillLimit() {
        #expect(InactiveConversationReactivator.reconnectionBackfillLimit == 5)
    }

    // MARK: - Helpers

    private func makeReactivator(fixtures: TestFixtures) -> InactiveConversationReactivator {
        InactiveConversationReactivator(
            databaseWriter: fixtures.databaseManager.dbWriter,
            databaseReader: fixtures.databaseManager.dbReader,
            localStateWriter: ConversationLocalStateWriter(
                databaseWriter: fixtures.databaseManager.dbWriter
            )
        )
    }

    private func seedConversation(
        in fixtures: TestFixtures,
        id: String,
        isActive: Bool
    ) async throws -> String {
        try await fixtures.databaseManager.dbWriter.write { db in
            let creatorInboxId = "inbox-\(id)"
            try DBMember(inboxId: creatorInboxId).save(db, onConflict: .ignore)
            try DBConversation(
                id: id,
                clientConversationId: id,
                inviteTag: "tag-\(id)",
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
            try DBConversationMember(
                conversationId: id,
                inboxId: creatorInboxId,
                role: .superAdmin,
                consent: .allowed,
                createdAt: Date(),
                invitedByInboxId: nil
            ).insert(db)
            try ConversationLocalState(
                conversationId: id,
                isPinned: false,
                isUnread: false,
                isUnreadUpdatedAt: Date(),
                isMuted: false,
                pinnedOrder: nil,
                isActive: isActive
            ).insert(db)
        }
        return id
    }

    private func seedUpdateMessage(
        in fixtures: TestFixtures,
        id: String,
        conversationId: String,
        date: Date
    ) async throws -> String {
        try await fixtures.databaseManager.dbWriter.write { db in
            let update = DBMessage.Update(
                initiatedByInboxId: "inbox-\(conversationId)",
                addedInboxIds: [],
                removedInboxIds: [],
                metadataChanges: [],
                expiresAt: nil
            )
            try DBMessage(
                id: id,
                clientMessageId: id,
                conversationId: conversationId,
                senderId: "inbox-\(conversationId)",
                dateNs: Int64(date.timeIntervalSince1970 * 1_000_000_000),
                date: date,
                sortId: nil,
                status: .published,
                messageType: .original,
                contentType: .update,
                text: nil,
                emoji: nil,
                invite: nil,
                linkPreview: nil,
                sourceMessageId: nil,
                attachmentUrls: [],
                update: update
            ).insert(db)
        }
        return id
    }

    private func seedTextMessage(
        in fixtures: TestFixtures,
        id: String,
        conversationId: String,
        date: Date
    ) async throws -> String {
        try await fixtures.databaseManager.dbWriter.write { db in
            try DBMessage(
                id: id,
                clientMessageId: id,
                conversationId: conversationId,
                senderId: "inbox-\(conversationId)",
                dateNs: Int64(date.timeIntervalSince1970 * 1_000_000_000),
                date: date,
                sortId: nil,
                status: .published,
                messageType: .original,
                contentType: .text,
                text: "hello",
                emoji: nil,
                invite: nil,
                linkPreview: nil,
                sourceMessageId: nil,
                attachmentUrls: [],
                update: nil
            ).insert(db)
        }
        return id
    }

    private func fetchLocalState(
        in fixtures: TestFixtures,
        conversationId: String
    ) async throws -> ConversationLocalState? {
        try await fixtures.databaseManager.dbReader.read { db in
            try ConversationLocalState
                .filter(ConversationLocalState.Columns.conversationId == conversationId)
                .fetchOne(db)
        }
    }

    private func fetchMessage(
        in fixtures: TestFixtures, id: String
    ) async throws -> DBMessage? {
        try await fixtures.databaseManager.dbReader.read { db in
            try DBMessage.fetchOne(db, key: id)
        }
    }
}
