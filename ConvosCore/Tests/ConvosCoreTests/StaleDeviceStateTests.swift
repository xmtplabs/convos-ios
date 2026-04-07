@testable import ConvosCore
import Foundation
import GRDB
import Testing

/// Tests for `InboxesRepository.staleDeviceStatePublisher` and `StaleDeviceState` derivation.
///
/// Verifies the partial-vs-full state model used to drive post-restore UX:
/// - healthy: no stale used inboxes
/// - partialStale: some but not all used inboxes are stale
/// - fullStale: every used inbox is stale
@Suite("StaleDeviceState derivation")
struct StaleDeviceStateTests {
    @Test("healthy when no inboxes exist")
    func testHealthyWhenNoInboxes() async throws {
        let fixtures = TestFixtures()
        let state = try await derivedState(in: fixtures)
        #expect(state == .healthy)
        try? await fixtures.cleanup()
    }

    @Test("healthy when there are inboxes but no conversations")
    func testHealthyWhenInboxHasNoConversations() async throws {
        let fixtures = TestFixtures()
        try await seedInbox(in: fixtures, id: "inbox-1", isVault: false, isStale: false)

        let state = try await derivedState(in: fixtures)
        // Inbox has no non-unused conversations → not "used" → healthy
        #expect(state == .healthy)
        try? await fixtures.cleanup()
    }

    @Test("healthy when used inbox is not stale")
    func testHealthyWhenUsedInboxIsNotStale() async throws {
        let fixtures = TestFixtures()
        try await seedInbox(in: fixtures, id: "inbox-1", isVault: false, isStale: false)
        try await seedConversation(in: fixtures, id: "conv-1", inboxId: "inbox-1")

        let state = try await derivedState(in: fixtures)
        #expect(state == .healthy)
        try? await fixtures.cleanup()
    }

    @Test("partialStale when one of two used inboxes is stale")
    func testPartialStaleWhenSomeUsedInboxesStale() async throws {
        let fixtures = TestFixtures()
        try await seedInbox(in: fixtures, id: "inbox-stale", isVault: false, isStale: true)
        try await seedInbox(in: fixtures, id: "inbox-healthy", isVault: false, isStale: false)
        try await seedConversation(in: fixtures, id: "conv-stale", inboxId: "inbox-stale")
        try await seedConversation(in: fixtures, id: "conv-healthy", inboxId: "inbox-healthy")

        let state = try await derivedState(in: fixtures)
        #expect(state == .partialStale)
        try? await fixtures.cleanup()
    }

    @Test("fullStale when every used inbox is stale")
    func testFullStaleWhenAllUsedInboxesStale() async throws {
        let fixtures = TestFixtures()
        try await seedInbox(in: fixtures, id: "inbox-1", isVault: false, isStale: true)
        try await seedInbox(in: fixtures, id: "inbox-2", isVault: false, isStale: true)
        try await seedConversation(in: fixtures, id: "conv-1", inboxId: "inbox-1")
        try await seedConversation(in: fixtures, id: "conv-2", inboxId: "inbox-2")

        let state = try await derivedState(in: fixtures)
        #expect(state == .fullStale)
        try? await fixtures.cleanup()
    }

    @Test("vault inboxes are not counted toward state")
    func testVaultInboxIsIgnored() async throws {
        let fixtures = TestFixtures()
        try await seedInbox(in: fixtures, id: "vault-inbox", isVault: true, isStale: false)
        try await seedInbox(in: fixtures, id: "user-inbox", isVault: false, isStale: true)
        try await seedConversation(in: fixtures, id: "conv-1", inboxId: "user-inbox")

        let state = try await derivedState(in: fixtures)
        // Only the user inbox counts; it's the only used inbox and it's stale → fullStale
        #expect(state == .fullStale)
        try? await fixtures.cleanup()
    }

    @Test("unused conversations do not count toward used-inbox check")
    func testUnusedConversationsAreIgnored() async throws {
        let fixtures = TestFixtures()
        try await seedInbox(in: fixtures, id: "inbox-1", isVault: false, isStale: true)
        try await seedConversation(in: fixtures, id: "conv-1", inboxId: "inbox-1", isUnused: true)

        let state = try await derivedState(in: fixtures)
        // Only conversation is unused → inbox is not "used" → healthy
        #expect(state == .healthy)
        try? await fixtures.cleanup()
    }

    @Test("StaleDeviceState convenience flags")
    func testConvenienceFlags() {
        #expect(StaleDeviceState.healthy.hasUsableInboxes == true)
        #expect(StaleDeviceState.healthy.hasAnyStaleInboxes == false)
        #expect(StaleDeviceState.partialStale.hasUsableInboxes == true)
        #expect(StaleDeviceState.partialStale.hasAnyStaleInboxes == true)
        #expect(StaleDeviceState.fullStale.hasUsableInboxes == false)
        #expect(StaleDeviceState.fullStale.hasAnyStaleInboxes == true)
    }

    // MARK: - Helpers

    private func derivedState(in fixtures: TestFixtures) async throws -> StaleDeviceState {
        try await fixtures.databaseManager.dbReader.read { db in
            let usedSql = """
                SELECT i.inboxId, i.isStale
                FROM inbox i
                WHERE i.isVault = 0
                  AND EXISTS (
                      SELECT 1
                      FROM conversation c
                      WHERE c.inboxId = i.inboxId
                        AND c.isUnused = 0
                  )
                """
            let rows = try Row.fetchAll(db, sql: usedSql)
            let total = rows.count
            let stale = rows.filter { $0["isStale"] as Bool == true }.count

            if total == 0 || stale == 0 {
                return StaleDeviceState.healthy
            }
            if stale == total {
                return StaleDeviceState.fullStale
            }
            return StaleDeviceState.partialStale
        }
    }

    private func seedInbox(
        in fixtures: TestFixtures,
        id: String,
        isVault: Bool,
        isStale: Bool
    ) async throws {
        try await fixtures.databaseManager.dbWriter.write { db in
            let inbox = DBInbox(
                inboxId: id,
                clientId: "client-\(id)",
                isVault: isVault,
                isStale: isStale
            )
            try inbox.save(db)
        }
    }

    private func seedConversation(
        in fixtures: TestFixtures,
        id: String,
        inboxId: String,
        isUnused: Bool = false
    ) async throws {
        try await fixtures.databaseManager.dbWriter.write { db in
            let conversation = DBConversation(
                id: id,
                inboxId: inboxId,
                clientId: "client-\(inboxId)",
                clientConversationId: id,
                inviteTag: "tag-\(id)",
                creatorId: inboxId,
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
                imageLastRenewed: nil,
                isUnused: isUnused
            )
            try conversation.save(db)
        }
    }
}
