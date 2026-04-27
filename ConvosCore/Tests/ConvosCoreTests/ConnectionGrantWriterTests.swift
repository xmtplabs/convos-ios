@testable import ConvosCore
import Foundation
import GRDB
import Testing

/// Tests for ConnectionGrantWriter
///
/// Covers the atomicity/rollback correctness of grant and revoke flows:
/// - grant succeeds → DB row present, metadata was published
/// - metadata publish fails → no DB row committed, error propagates
/// - revoke succeeds → DB row removed, metadata was published with reduced set
/// - revoke publish fails → DB row remains, error propagates
@Suite("ConnectionGrantWriter Tests")
struct ConnectionGrantWriterTests {
    // MARK: - Fixtures

    private struct Fixture {
        let databaseManager: MockDatabaseManager
        let sessionStateManager: MockSessionStateManager
        let profileWriter: MockMyProfileWriter
        let writer: ConnectionGrantWriter

        init(inboxId: String = "mock-inbox-id") {
            let databaseManager = MockDatabaseManager.makeTestDatabase()
            let profileWriter = MockMyProfileWriter()
            let mockClient = MockXMTPClientProvider(inboxId: inboxId)
            let sessionStateManager = MockSessionStateManager(mockClient: mockClient)
            self.databaseManager = databaseManager
            self.sessionStateManager = sessionStateManager
            self.profileWriter = profileWriter
            self.writer = ConnectionGrantWriter(
                sessionStateManager: sessionStateManager,
                databaseWriter: databaseManager.dbWriter,
                databaseReader: databaseManager.dbReader,
                myProfileWriter: profileWriter
            )
        }

        func seedConnection(
            id: String = "conn_google_cal",
            serviceId: String = "google_calendar",
            status: ConnectionStatus = .active
        ) throws -> DBConnection {
            let connection = DBConnection(
                id: id,
                serviceId: serviceId,
                serviceName: "Google Calendar",
                provider: ConnectionProvider.composio.rawValue,
                composioEntityId: "entity_abc",
                composioConnectionId: "ca_abc",
                status: status.rawValue,
                connectedAt: Date()
            )
            try databaseManager.dbWriter.write { db in
                try connection.save(db)
            }
            return connection
        }

        func seedConversation(id: String) throws {
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
                expiresAt: nil,
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
            connectionId: String,
            conversationId: String,
            serviceId: String
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

        func storedGrants(for conversationId: String) throws -> [DBConnectionGrant] {
            try databaseManager.dbReader.read { db in
                try DBConnectionGrant
                    .filter(DBConnectionGrant.Columns.conversationId == conversationId)
                    .fetchAll(db)
            }
        }

        func cleanup() {
            try? databaseManager.erase()
        }
    }

    // MARK: - Grant flow

    @Test("Grant: publish succeeds then DB row is persisted and metadata carries the new grant")
    func grantPersistsAfterSuccessfulPublish() async throws {
        let fixture = Fixture()
        defer { fixture.cleanup() }

        let connection = try fixture.seedConnection()
        let conversationId = "conv_1"
        try fixture.seedConversation(id: conversationId)

        try await fixture.writer.grantConnection(connection.id, to: conversationId)

        let stored = try fixture.storedGrants(for: conversationId)
        #expect(stored.count == 1)
        #expect(stored.first?.connectionId == connection.id)
        #expect(stored.first?.serviceId == connection.serviceId)

        #expect(fixture.profileWriter.publishedMetadata.count == 1)
        let published = try #require(fixture.profileWriter.publishedMetadata.first)
        #expect(published.conversationId == conversationId)
        let metadata = try #require(published.metadata)
        guard case .string(let grantsJson) = try #require(metadata["connections"]) else {
            Issue.record("connections entry was not a string")
            return
        }
        let payload = try ConnectionsMetadataPayload.fromJsonString(grantsJson)
        #expect(payload.grants.count == 1)
        #expect(payload.grants.first?.composioConnectionId == connection.composioConnectionId)
        #expect(payload.grants.first?.service == connection.serviceId)
    }

    @Test("Grant: publish failure leaves no DB row and propagates the error")
    func grantRollsBackWhenPublishFails() async throws {
        let fixture = Fixture()
        defer { fixture.cleanup() }

        let connection = try fixture.seedConnection()
        let conversationId = "conv_2"
        try fixture.seedConversation(id: conversationId)

        struct PublishFailure: Error, Equatable {}
        fixture.profileWriter.publishError = PublishFailure()

        var caughtExpectedError: Bool = false
        do {
            try await fixture.writer.grantConnection(connection.id, to: conversationId)
            Issue.record("Expected grantConnection to throw")
        } catch is PublishFailure {
            caughtExpectedError = true
        } catch {
            Issue.record("Expected PublishFailure but got \(error)")
        }
        #expect(caughtExpectedError)

        let stored = try fixture.storedGrants(for: conversationId)
        #expect(stored.isEmpty, "no grant row should be committed after a publish failure")
    }

    @Test("Grant: connection not found throws without touching DB or publishing")
    func grantThrowsWhenConnectionMissing() async throws {
        let fixture = Fixture()
        defer { fixture.cleanup() }

        await #expect(throws: ConnectionGrantError.self) {
            try await fixture.writer.grantConnection("missing", to: "conv_x")
        }
        #expect(fixture.profileWriter.publishedMetadata.isEmpty)
        let stored = try fixture.storedGrants(for: "conv_x")
        #expect(stored.isEmpty)
    }

    @Test("Grant: rejects inactive connections without publishing")
    func grantRejectsInactiveConnection() async throws {
        let fixture = Fixture()
        defer { fixture.cleanup() }

        let connection = try fixture.seedConnection(id: "conn_inactive", status: .revoked)

        await #expect(throws: ConnectionGrantError.self) {
            try await fixture.writer.grantConnection(connection.id, to: "conv_x")
        }
        #expect(fixture.profileWriter.publishedMetadata.isEmpty)
    }

    // MARK: - Revoke flow

    @Test("Revoke: publish succeeds then DB row is removed and metadata is cleared")
    func revokeRemovesGrantAfterSuccessfulPublish() async throws {
        let fixture = Fixture()
        defer { fixture.cleanup() }

        let connection = try fixture.seedConnection()
        let conversationId = "conv_rev"
        try fixture.seedConversation(id: conversationId)
        try fixture.seedGrant(
            connectionId: connection.id,
            conversationId: conversationId,
            serviceId: connection.serviceId
        )

        try await fixture.writer.revokeGrant(connectionId: connection.id, from: conversationId)

        let stored = try fixture.storedGrants(for: conversationId)
        #expect(stored.isEmpty)

        // The published metadata should have cleared the connections entry.
        #expect(fixture.profileWriter.publishedMetadata.count == 1)
        let published = try #require(fixture.profileWriter.publishedMetadata.first)
        #expect(published.conversationId == conversationId)
        // With no remaining grants the writer passes nil metadata (empty map collapses).
        #expect(published.metadata == nil)
    }

    @Test("Revoke: publish failure leaves the DB row intact and propagates the error")
    func revokeRollsBackWhenPublishFails() async throws {
        let fixture = Fixture()
        defer { fixture.cleanup() }

        let connection = try fixture.seedConnection()
        let conversationId = "conv_rev_fail"
        try fixture.seedConversation(id: conversationId)
        try fixture.seedGrant(
            connectionId: connection.id,
            conversationId: conversationId,
            serviceId: connection.serviceId
        )

        struct PublishFailure: Error, Equatable {}
        fixture.profileWriter.publishError = PublishFailure()

        var caughtExpectedError: Bool = false
        do {
            try await fixture.writer.revokeGrant(connectionId: connection.id, from: conversationId)
            Issue.record("Expected revokeGrant to throw")
        } catch is PublishFailure {
            caughtExpectedError = true
        } catch {
            Issue.record("Expected PublishFailure but got \(error)")
        }
        #expect(caughtExpectedError)

        let stored = try fixture.storedGrants(for: conversationId)
        #expect(stored.count == 1, "grant row should remain when publish fails")
        #expect(stored.first?.connectionId == connection.id)
    }

    @Test("Revoke: no-op when grant does not exist")
    func revokeNoOpWhenGrantMissing() async throws {
        let fixture = Fixture()
        defer { fixture.cleanup() }

        try await fixture.writer.revokeGrant(connectionId: "nope", from: "conv_nope")

        #expect(fixture.profileWriter.publishedMetadata.isEmpty)
        let stored = try fixture.storedGrants(for: "conv_nope")
        #expect(stored.isEmpty)
    }

    // MARK: - Multi-grant projection

    @Test("Grant: publishes the union of existing and new grants")
    func grantPublishesUnion() async throws {
        let fixture = Fixture()
        defer { fixture.cleanup() }

        let first = try fixture.seedConnection(id: "conn_a", serviceId: "google_calendar")
        let second = try fixture.seedConnection(id: "conn_b", serviceId: "google_drive")
        let conversationId = "conv_multi"
        try fixture.seedConversation(id: conversationId)

        try await fixture.writer.grantConnection(first.id, to: conversationId)
        try await fixture.writer.grantConnection(second.id, to: conversationId)

        let stored = try fixture.storedGrants(for: conversationId)
        #expect(stored.count == 2)

        #expect(fixture.profileWriter.publishedMetadata.count == 2)
        let lastPublish = try #require(fixture.profileWriter.publishedMetadata.last)
        let metadata = try #require(lastPublish.metadata)
        guard case .string(let grantsJson) = try #require(metadata["connections"]) else {
            Issue.record("connections entry was not a string")
            return
        }
        let payload = try ConnectionsMetadataPayload.fromJsonString(grantsJson)
        #expect(payload.grants.count == 2)
        let serviceIds = Set(payload.grants.map(\.service))
        #expect(serviceIds == ["google_calendar", "google_drive"])
    }
}
