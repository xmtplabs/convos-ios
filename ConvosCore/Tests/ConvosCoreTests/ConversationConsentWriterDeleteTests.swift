@testable import ConvosCore
import Foundation
import GRDB
import Testing

/// Coverage for `ConversationConsentWriter.delete(conversation:)` — the path
/// that powers the conversations-list "Delete" action. The writer must flip
/// the local DB row's `consent` column to `.denied` so that the next
/// `ConversationsRepository(for: [.allowed])` emit filters the row out and
/// the delete survives an app restart.
@Suite("ConversationConsentWriter delete persistence", .serialized)
struct ConversationConsentWriterDeleteTests {
    @Test("delete(conversation:) writes consent=.denied to the local DB row")
    func deleteFlipsConsentToDenied() async throws {
        let dbManager = MockDatabaseManager.makeTestDatabase()
        let conversationId = "conv-delete-1"
        try seedAllowedConversation(in: dbManager.dbWriter, conversationId: conversationId)

        let writer = ConversationConsentWriter(
            sessionStateManager: MockSessionStateManager(),
            databaseWriter: dbManager.dbWriter
        )

        try await writer.delete(conversation: .mock(id: conversationId))

        let stored = try await dbManager.dbReader.read { db in
            try DBConversation.fetchOne(db, id: conversationId)
        }
        #expect(stored?.consent == .denied)
    }

    @Test("delete(conversation:) no-ops cleanly when the DB row is missing")
    func deleteWithMissingRowIsNoOp() async throws {
        let dbManager = MockDatabaseManager.makeTestDatabase()

        let writer = ConversationConsentWriter(
            sessionStateManager: MockSessionStateManager(),
            databaseWriter: dbManager.dbWriter
        )

        try await writer.delete(conversation: .mock(id: "conv-missing"))

        let stored = try await dbManager.dbReader.read { db in
            try DBConversation.fetchOne(db, id: "conv-missing")
        }
        #expect(stored == nil)
    }

    @Test("delete(conversation:) on a pending-invite draft writes the local denial without contacting XMTP")
    func deleteDraftWritesLocalDenialWithoutXMTP() async throws {
        let dbManager = MockDatabaseManager.makeTestDatabase()
        let draftId = "draft-verifying-1"
        try seedAllowedConversation(in: dbManager.dbWriter, conversationId: draftId)

        // A pending-invite draft has no XMTP group to deny, so the writer
        // must not touch the network path at all. A session manager that
        // cannot vend a client proves the draft branch never asks for one --
        // before the draft-aware fix this delete threw and the local denial
        // was never written, so the conversation popped back into the list.
        let writer = ConversationConsentWriter(
            sessionStateManager: InboxUnavailableSessionStateManager(),
            databaseWriter: dbManager.dbWriter
        )

        try await writer.delete(conversation: .mock(id: draftId))

        let stored = try await dbManager.dbReader.read { db in
            try DBConversation.fetchOne(db, id: draftId)
        }
        #expect(stored?.consent == .denied)
    }

    @Test("delete(conversation:) with a stale draft id re-targets the row that replaced the draft")
    func deleteStaleDraftIdRetargetsReplacementRow() async throws {
        let dbManager = MockDatabaseManager.makeTestDatabase()
        // The invite resolved while the delete was in flight: the draft row
        // is gone and the real group's row kept the draft id as its sticky
        // clientConversationId.
        let draftId = "draft-resolved-1"
        let realId = "real-group-resolved-1"
        try seedAllowedConversation(
            in: dbManager.dbWriter,
            conversationId: realId,
            clientConversationId: draftId
        )

        let writer = ConversationConsentWriter(
            sessionStateManager: MockSessionStateManager(),
            databaseWriter: dbManager.dbWriter
        )

        try await writer.delete(conversation: .mock(id: draftId))

        let stored = try await dbManager.dbReader.read { db in
            try DBConversation.fetchOne(db, id: realId)
        }
        #expect(stored?.consent == .denied)
    }

    @Test("delete(conversation:) with a stale draft id uses the networked denial for the replacement row")
    func deleteStaleDraftIdRequiresClientForReplacementRow() async throws {
        let dbManager = MockDatabaseManager.makeTestDatabase()
        let draftId = "draft-resolved-2"
        let realId = "real-group-resolved-2"
        try seedAllowedConversation(
            in: dbManager.dbWriter,
            conversationId: realId,
            clientConversationId: draftId
        )

        // Once the draft resolved to a real group, the denial must go
        // through XMTP -- an unavailable inbox has to fail the delete
        // instead of silently denying only the local row.
        let writer = ConversationConsentWriter(
            sessionStateManager: InboxUnavailableSessionStateManager(),
            databaseWriter: dbManager.dbWriter
        )

        await #expect(throws: (any Error).self) {
            try await writer.delete(conversation: .mock(id: draftId))
        }

        let stored = try await dbManager.dbReader.read { db in
            try DBConversation.fetchOne(db, id: realId)
        }
        #expect(stored?.consent == .allowed)
    }

    @Test("delete(conversation:) on a real conversation still requires the XMTP client")
    func deleteRealConversationStillRequiresClient() async throws {
        let dbManager = MockDatabaseManager.makeTestDatabase()
        let conversationId = "conv-real-1"
        try seedAllowedConversation(in: dbManager.dbWriter, conversationId: conversationId)

        let writer = ConversationConsentWriter(
            sessionStateManager: InboxUnavailableSessionStateManager(),
            databaseWriter: dbManager.dbWriter
        )

        await #expect(throws: (any Error).self) {
            try await writer.delete(conversation: .mock(id: conversationId))
        }

        let stored = try await dbManager.dbReader.read { db in
            try DBConversation.fetchOne(db, id: conversationId)
        }
        #expect(stored?.consent == .allowed)
    }

    @Test("delete(conversation:) on a real conversation unsubscribes its group push topic")
    func deleteUnsubscribesGroupPushTopic() async throws {
        let dbManager = MockDatabaseManager.makeTestDatabase()
        let conversationId = "conv-unsub-1"
        try seedAllowedConversation(in: dbManager.dbWriter, conversationId: conversationId)

        let recordingManager = RecordingGroupUnsubscribeManager()
        let writer = ConversationConsentWriter(
            sessionStateManager: MockSessionStateManager(),
            databaseWriter: dbManager.dbWriter,
            pushTopicSubscriptionManager: recordingManager
        )

        try await writer.delete(conversation: .mock(id: conversationId))

        let unsubscribed = await recordingManager.unsubscribedGroupIds
        #expect(unsubscribed == [conversationId])
    }

    @Test("delete(conversation:) on a pending-invite draft does not unsubscribe a group topic")
    func deleteDraftDoesNotUnsubscribeGroupPushTopic() async throws {
        let dbManager = MockDatabaseManager.makeTestDatabase()
        let draftId = "draft-unsub-1"
        try seedAllowedConversation(in: dbManager.dbWriter, conversationId: draftId)

        // A draft has no XMTP group, so there is no group topic to drop. The
        // writer must not even reach the network path for a draft.
        let recordingManager = RecordingGroupUnsubscribeManager()
        let writer = ConversationConsentWriter(
            sessionStateManager: InboxUnavailableSessionStateManager(),
            databaseWriter: dbManager.dbWriter,
            pushTopicSubscriptionManager: recordingManager
        )

        try await writer.delete(conversation: .mock(id: draftId))

        let unsubscribed = await recordingManager.unsubscribedGroupIds
        #expect(unsubscribed.isEmpty)
    }

    @Test("After delete, a fetch filtered on [.allowed] no longer returns the row")
    func repositoryFilterExcludesDeniedRow() async throws {
        let dbManager = MockDatabaseManager.makeTestDatabase()
        let conversationId = "conv-delete-2"
        try seedAllowedConversation(in: dbManager.dbWriter, conversationId: conversationId)

        let beforeDelete = try await dbManager.dbReader.read { db in
            try DBConversation
                .filter([Consent.allowed].contains(DBConversation.Columns.consent))
                .filter(DBConversation.Columns.id == conversationId)
                .fetchOne(db)
        }
        #expect(beforeDelete?.consent == .allowed)

        let writer = ConversationConsentWriter(
            sessionStateManager: MockSessionStateManager(),
            databaseWriter: dbManager.dbWriter
        )
        try await writer.delete(conversation: .mock(id: conversationId))

        let afterDelete = try await dbManager.dbReader.read { db in
            try DBConversation
                .filter([Consent.allowed].contains(DBConversation.Columns.consent))
                .filter(DBConversation.Columns.id == conversationId)
                .fetchOne(db)
        }
        #expect(afterDelete == nil)
    }
}

// MARK: - Helpers

/// Session manager whose inbox never becomes ready. Used to prove a code
/// path completes without ever needing the XMTP client.
private final class InboxUnavailableSessionStateManager: SessionStateManagerProtocol, @unchecked Sendable {
    struct InboxUnavailableError: Error {}

    var currentState: SessionStateMachine.State = .idle
    var isSyncReady: Bool { false }

    func waitForInboxReadyResult() async throws -> InboxReadyResult {
        throw InboxUnavailableError()
    }

    func waitForDeletionComplete() async {}
    func setInviteJoinErrorHandler(_ handler: (any InviteJoinErrorHandler)?) async {}
    func setTypingIndicatorHandler(_ handler: @escaping @Sendable (String, String, Bool) -> Void) async {}
    func requestDiscovery() async {}
    func runHistorySyncBackfill() async {}
    func startAgentJoinRequestPolling() async {}
    func addObserver(_ observer: SessionStateObserver) {}
    func removeObserver(_ observer: SessionStateObserver) {}

    func observeState(_ handler: @escaping (SessionStateMachine.State) -> Void) -> StateObserverHandle {
        StateObserverHandle(observer: ClosureStateObserver(handler: handler), manager: self)
    }
}

/// Records group-topic unsubscribe calls so the leave path can be asserted
/// without a live backend. Other protocol methods are no-ops.
private actor RecordingGroupUnsubscribeManager: PushTopicSubscriptionManaging {
    private(set) var unsubscribedGroupIds: [String] = []

    func subscribeToGroupAndWelcome(conversationId: String, params: SyncClientParams, context: String) async {}
    func subscribeToInviteDMTopic(conversationId: String, params: SyncClientParams, context: String) async {}
    func unsubscribeFromInviteDMTopic(conversationId: String, params: SyncClientParams, context: String) async {}

    func unsubscribeFromGroupTopic(conversationId: String, params: SyncClientParams, context: String) async {
        unsubscribedGroupIds.append(conversationId)
    }

    func reconcilePushTopics(params: SyncClientParams, context: String) async {}
    func clearCache() async {}
}

private func seedAllowedConversation(
    in writer: any DatabaseWriter,
    conversationId: String,
    clientConversationId: String? = nil
) throws {
    try writer.write { db in
        try DBConversation(
            id: conversationId,
            clientConversationId: clientConversationId ?? "client-\(conversationId)",
            inviteTag: "invite-\(conversationId)",
            creatorId: "inbox-1",
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
}
