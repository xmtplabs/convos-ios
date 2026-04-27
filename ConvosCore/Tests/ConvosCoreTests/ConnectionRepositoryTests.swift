@testable import ConvosCore
import Foundation
import GRDB
import Testing

/// Tests for ConnectionRepository.
///
/// Focus area: `grants(for:)` and `grantsPublisher(for:)` must hide grants
/// belonging to expired conversations. The FK on
/// `connectionGrant.conversationId → conversation(id) ON DELETE CASCADE`
/// only fires when the conversation row is deleted, but
/// `ExpiredConversationsWorker` keeps the row around past `expiresAt`, so the
/// repository owns the active-only contract.
@Suite("ConnectionRepository Tests")
struct ConnectionRepositoryTests {
    private struct Fixture {
        let databaseManager: MockDatabaseManager
        let repository: ConnectionRepository

        init() {
            let databaseManager = MockDatabaseManager.makeTestDatabase()
            self.databaseManager = databaseManager
            self.repository = ConnectionRepository(databaseReader: databaseManager.dbReader)
        }

        @discardableResult
        func seedConnection(
            id: String = "conn_google_cal",
            serviceId: String = "google_calendar"
        ) throws -> DBConnection {
            let connection = DBConnection(
                id: id,
                serviceId: serviceId,
                serviceName: "Google Calendar",
                provider: ConnectionProvider.composio.rawValue,
                composioEntityId: "entity_abc",
                composioConnectionId: "ca_abc",
                status: ConnectionStatus.active.rawValue,
                connectedAt: Date()
            )
            try databaseManager.dbWriter.write { db in
                try connection.save(db)
            }
            return connection
        }

        func seedConversation(id: String, expiresAt: Date?) throws {
            let conversation = DBConversation(
                id: id,
                clientConversationId: id,
                inviteTag: "invite-\(id)",
                creatorId: "test-inbox",
                kind: .group,
                consent: .allowed,
                createdAt: Date(),
                name: nil,
                description: nil,
                imageURLString: nil,
                publicImageURLString: nil,
                includeInfoInPublicPreview: false,
                expiresAt: expiresAt,
                debugInfo: .empty,
                isLocked: false,
                imageSalt: nil,
                imageNonce: nil,
                imageEncryptionKey: nil,
                conversationEmoji: nil,
                imageLastRenewed: nil,
                isUnused: false,
                hasHadVerifiedAssistant: false,
            )
            try databaseManager.dbWriter.write { db in
                try conversation.save(db)
            }
        }

        func seedGrant(
            connectionId: String = "conn_google_cal",
            conversationId: String,
            serviceId: String = "google_calendar"
        ) throws {
            let grant = DBConnectionGrant(
                connectionId: connectionId,
                conversationId: conversationId,
                serviceId: serviceId,
                grantedAt: Date()
            )
            try databaseManager.dbWriter.write { db in
                try grant.save(db)
            }
        }

        func cleanup() {
            try? databaseManager.erase()
        }
    }

    @Test("Active conversation: grants are returned")
    func grantsReturnedForActiveConversation() async throws {
        let fixture = Fixture()
        defer { fixture.cleanup() }
        try fixture.seedConnection()
        try fixture.seedConversation(id: "conv_active", expiresAt: nil)
        try fixture.seedGrant(conversationId: "conv_active")

        let grants = try await fixture.repository.grants(for: "conv_active")
        #expect(grants.count == 1)
        #expect(grants.first?.conversationId == "conv_active")
    }

    @Test("Conversation with future expiresAt: grants are returned")
    func grantsReturnedForFutureExpiry() async throws {
        let fixture = Fixture()
        defer { fixture.cleanup() }
        try fixture.seedConnection()
        let future = Date().addingTimeInterval(3_600)
        try fixture.seedConversation(id: "conv_future", expiresAt: future)
        try fixture.seedGrant(conversationId: "conv_future")

        let grants = try await fixture.repository.grants(for: "conv_future")
        #expect(grants.count == 1)
    }

    @Test("Expired conversation: grants are hidden even though the rows exist")
    func grantsHiddenForExpiredConversation() async throws {
        let fixture = Fixture()
        defer { fixture.cleanup() }
        try fixture.seedConnection()
        let past = Date().addingTimeInterval(-3_600)
        try fixture.seedConversation(id: "conv_expired", expiresAt: past)
        try fixture.seedGrant(conversationId: "conv_expired")

        let grants = try await fixture.repository.grants(for: "conv_expired")
        #expect(grants.isEmpty)

        // Confirm the grant rows still exist in the DB — the filter is at the
        // repository read layer, not a delete.
        let raw = try await fixture.databaseManager.dbReader.read { db in
            try DBConnectionGrant
                .filter(DBConnectionGrant.Columns.conversationId == "conv_expired")
                .fetchAll(db)
        }
        #expect(raw.count == 1)
    }

    @Test("Conversation row missing: returns no grants (no crash)")
    func noConversationReturnsEmpty() async throws {
        let fixture = Fixture()
        defer { fixture.cleanup() }
        // No conversation row, no grants either — repository should return empty.
        let grants = try await fixture.repository.grants(for: "conv_nonexistent")
        #expect(grants.isEmpty)
    }
}
