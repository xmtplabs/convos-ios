@testable import ConvosCore
import Foundation
import GRDB
import Testing
import XMTPiOS

/// Regression tests for `ConversationWriter.saveConversation` preserving
/// `quarantinedAt` and `quarantineReleasedAt` across re-stores.
///
/// Bug: `_store` and `createDBConversation` thread `quarantinedAt` through
/// to a fresh `DBConversation`, but `quarantineReleasedAt` is never
/// threaded and the default `quarantinedAt` from `store(...)` /
/// `storeWithLatestMessages(...)` is `nil`. Without explicit preservation
/// in `saveConversation`, every normal sync (push notification refresh,
/// metadata update, etc.) silently overwrote both fields with `nil`,
/// un-quarantining a held conversation just because a network refresh
/// landed.
@Suite("Conversation Quarantine State Preservation Tests")
struct ConversationQuarantinePreservationTests {
    private enum TestError: Error {
        case missingClients
    }

    @Test("Re-storing a quarantined conversation preserves its quarantinedAt")
    func testRestorePreservesQuarantinedAt() async throws {
        let fixtures = TestFixtures()
        try await fixtures.createTestClients()

        guard let clientA = fixtures.clientA as? Client,
              let clientB = fixtures.clientB,
              let clientIdA = fixtures.clientIdA else {
            throw TestError.missingClients
        }

        let inboxIdA = clientA.inboxID

        try await fixtures.databaseManager.dbWriter.write { db in
            try DBInbox(inboxId: inboxIdA, clientId: clientIdA, createdAt: Date()).insert(db)
        }

        let group = try await clientA.conversations.newGroup(
            with: [clientB.inboxId],
            name: "Test Group",
            imageUrl: "",
            description: ""
        )
        let conversationId = group.id

        let conversationWriter = ConversationWriter(
            identityStore: fixtures.identityStore,
            databaseWriter: fixtures.databaseManager.dbWriter,
            messageWriter: MockIncomingMessageWriter()
        )

        // Initial store with explicit quarantine — simulates the stream
        // processor's quarantine path on a brand-new inbound conversation.
        let quarantinedAt = Date(timeIntervalSinceNow: -120)
        _ = try await conversationWriter.storeWithLatestMessages(
            conversation: group,
            inboxId: inboxIdA,
            clientConversationId: nil,
            quarantinedAt: quarantinedAt
        )

        let afterFirstStore = try await fixtures.databaseManager.dbReader.read { db in
            try DBConversation.fetchOne(db, id: conversationId)
        }
        let firstStoredQuarantinedAt = try #require(afterFirstStore?.quarantinedAt)
        #expect(abs(firstStoredQuarantinedAt.timeIntervalSince(quarantinedAt)) < 1)

        // Subsequent store with no quarantine arg — simulates a normal
        // sync (push notification refresh, metadata update, etc.). Before
        // the fix this overwrote `quarantinedAt` with `nil`.
        _ = try await conversationWriter.store(
            conversation: group,
            inboxId: inboxIdA,
            clientConversationId: nil
        )

        let afterRefresh = try await fixtures.databaseManager.dbReader.read { db in
            try DBConversation.fetchOne(db, id: conversationId)
        }
        let preservedQuarantinedAt = try #require(afterRefresh?.quarantinedAt)
        #expect(abs(preservedQuarantinedAt.timeIntervalSince(quarantinedAt)) < 1)

        try? await fixtures.cleanup()
    }

    @Test("Re-storing a released conversation preserves its quarantineReleasedAt")
    func testRestorePreservesQuarantineReleasedAt() async throws {
        let fixtures = TestFixtures()
        try await fixtures.createTestClients()

        guard let clientA = fixtures.clientA as? Client,
              let clientB = fixtures.clientB,
              let clientIdA = fixtures.clientIdA else {
            throw TestError.missingClients
        }

        let inboxIdA = clientA.inboxID

        try await fixtures.databaseManager.dbWriter.write { db in
            try DBInbox(inboxId: inboxIdA, clientId: clientIdA, createdAt: Date()).insert(db)
        }

        let group = try await clientA.conversations.newGroup(
            with: [clientB.inboxId],
            name: "Test Group",
            imageUrl: "",
            description: ""
        )
        let conversationId = group.id

        let conversationWriter = ConversationWriter(
            identityStore: fixtures.identityStore,
            databaseWriter: fixtures.databaseManager.dbWriter,
            messageWriter: MockIncomingMessageWriter()
        )

        _ = try await conversationWriter.store(
            conversation: group,
            inboxId: inboxIdA,
            clientConversationId: nil
        )

        // Simulate the sweeper releasing the conversation by writing
        // directly to the row. The sweeper bypasses ConversationWriter, so
        // this matches its real behavior.
        let quarantinedAt = Date(timeIntervalSinceNow: -3_600)
        let releasedAt = Date(timeIntervalSinceNow: -60)
        try await fixtures.databaseManager.dbWriter.write { db in
            try db.execute(
                sql: "UPDATE conversation SET quarantinedAt = ?, quarantineReleasedAt = ? WHERE id = ?",
                arguments: [quarantinedAt, releasedAt, conversationId]
            )
        }

        // A normal sync after release should keep the released marker.
        // Without preservation the row would lose `quarantineReleasedAt`
        // and re-enter the quarantined-but-not-released state, dropping
        // the conversation back out of the main feed.
        _ = try await conversationWriter.store(
            conversation: group,
            inboxId: inboxIdA,
            clientConversationId: nil
        )

        let afterRefresh = try await fixtures.databaseManager.dbReader.read { db in
            try DBConversation.fetchOne(db, id: conversationId)
        }
        let preservedQuarantinedAt = try #require(afterRefresh?.quarantinedAt)
        let preservedReleasedAt = try #require(afterRefresh?.quarantineReleasedAt)
        #expect(abs(preservedQuarantinedAt.timeIntervalSince(quarantinedAt)) < 1)
        #expect(abs(preservedReleasedAt.timeIntervalSince(releasedAt)) < 1)

        try? await fixtures.cleanup()
    }

    @Test("Explicit non-nil quarantinedAt on re-store wins over existing value")
    func testExplicitQuarantinedAtWinsOverExisting() async throws {
        let fixtures = TestFixtures()
        try await fixtures.createTestClients()

        guard let clientA = fixtures.clientA as? Client,
              let clientB = fixtures.clientB,
              let clientIdA = fixtures.clientIdA else {
            throw TestError.missingClients
        }

        let inboxIdA = clientA.inboxID

        try await fixtures.databaseManager.dbWriter.write { db in
            try DBInbox(inboxId: inboxIdA, clientId: clientIdA, createdAt: Date()).insert(db)
        }

        let group = try await clientA.conversations.newGroup(
            with: [clientB.inboxId],
            name: "Test Group",
            imageUrl: "",
            description: ""
        )
        let conversationId = group.id

        let conversationWriter = ConversationWriter(
            identityStore: fixtures.identityStore,
            databaseWriter: fixtures.databaseManager.dbWriter,
            messageWriter: MockIncomingMessageWriter()
        )

        let firstQuarantinedAt = Date(timeIntervalSinceNow: -3_600)
        _ = try await conversationWriter.storeWithLatestMessages(
            conversation: group,
            inboxId: inboxIdA,
            clientConversationId: nil,
            quarantinedAt: firstQuarantinedAt
        )

        // Re-quarantine with a fresh timestamp — the explicit non-nil
        // value should win over the stored one, otherwise the stream
        // processor couldn't correct a stale quarantine timestamp.
        let secondQuarantinedAt = Date()
        _ = try await conversationWriter.storeWithLatestMessages(
            conversation: group,
            inboxId: inboxIdA,
            clientConversationId: nil,
            quarantinedAt: secondQuarantinedAt
        )

        let afterReQuarantine = try await fixtures.databaseManager.dbReader.read { db in
            try DBConversation.fetchOne(db, id: conversationId)
        }
        let storedQuarantinedAt = try #require(afterReQuarantine?.quarantinedAt)
        #expect(abs(storedQuarantinedAt.timeIntervalSince(secondQuarantinedAt)) < 1)
        #expect(abs(storedQuarantinedAt.timeIntervalSince(firstQuarantinedAt)) > 60)

        try? await fixtures.cleanup()
    }
}
