@testable import ConvosCore
import Foundation
import GRDB
import Testing

/// Tests for CloudConnectionGrantWriter
///
/// Covers the atomicity/rollback correctness of grant and revoke flows:
/// - grant succeeds → DB row present, metadata was published
/// - metadata publish fails → no DB row committed, error propagates
/// - revoke succeeds → DB row removed, metadata was published with reduced set
/// - revoke publish fails → DB row remains, error propagates
@Suite("CloudConnectionGrantWriter Tests")
struct ConnectionGrantWriterTests {
    // MARK: - Fixtures

    private struct Fixture {
        let databaseManager: MockDatabaseManager
        let sessionStateManager: MockSessionStateManager
        let profileWriter: MockMyProfileWriter
        let writer: CloudConnectionGrantWriter

        init(inboxId: String = "mock-inbox-id", apiClient: (any ConvosAPIClientProtocol)? = nil) {
            let databaseManager = MockDatabaseManager.makeTestDatabase()
            let profileWriter = MockMyProfileWriter()
            let mockClient = MockXMTPClientProvider(inboxId: inboxId)
            let sessionStateManager = MockSessionStateManager(mockClient: mockClient, mockAPIClient: apiClient)
            self.databaseManager = databaseManager
            self.sessionStateManager = sessionStateManager
            self.profileWriter = profileWriter
            self.writer = CloudConnectionGrantWriter(
                sessionStateManager: sessionStateManager,
                databaseWriter: databaseManager.dbWriter,
                databaseReader: databaseManager.dbReader,
                myProfileWriter: profileWriter
            )
        }

        func seedConnection(
            id: String = "conn_google_cal",
            serviceId: String = "googlecalendar",
            status: CloudConnectionStatus = .active
        ) throws -> DBCloudConnection {
            let connection = DBCloudConnection(
                id: id,
                serviceId: serviceId,
                serviceName: "Google Calendar",
                provider: CloudConnectionProvider.composio.rawValue,
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
                hasHadVerifiedAgent: false,
            )
            try databaseManager.dbWriter.write { db in
                try conversation.save(db)
            }
        }

        func seedGrant(
            connectionId: String,
            conversationId: String,
            serviceId: String,
            grantedToInboxId: String = "agent-1",
            backendGrantId: String? = nil
        ) throws {
            let grant = DBCloudConnectionGrant(
                connectionId: connectionId,
                conversationId: conversationId,
                serviceId: serviceId,
                grantedToInboxId: grantedToInboxId,
                grantedAt: Date(),
                backendGrantId: backendGrantId
            )
            try databaseManager.dbWriter.write { db in
                try grant.save(db)
            }
        }

        func storedGrants(for conversationId: String) throws -> [DBCloudConnectionGrant] {
            try databaseManager.dbReader.read { db in
                try DBCloudConnectionGrant
                    .filter(DBCloudConnectionGrant.Columns.conversationId == conversationId)
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

        try await fixture.writer.grantConnection(connection.id, to: conversationId, grantedToInboxId: "agent-1")

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
        let payload = try CloudConnectionsMetadataPayload.fromJsonString(grantsJson)
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
            try await fixture.writer.grantConnection(connection.id, to: conversationId, grantedToInboxId: "agent-1")
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

        await #expect(throws: CloudConnectionGrantError.self) {
            try await fixture.writer.grantConnection("missing", to: "conv_x", grantedToInboxId: "agent-1")
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

        await #expect(throws: CloudConnectionGrantError.self) {
            try await fixture.writer.grantConnection(connection.id, to: "conv_x", grantedToInboxId: "agent-1")
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

        try await fixture.writer.revokeGrant(connectionId: connection.id, from: conversationId, grantedToInboxId: "agent-1")

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
            try await fixture.writer.revokeGrant(connectionId: connection.id, from: conversationId, grantedToInboxId: "agent-1")
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

        try await fixture.writer.revokeGrant(connectionId: "nope", from: "conv_nope", grantedToInboxId: "agent-1")

        #expect(fixture.profileWriter.publishedMetadata.isEmpty)
        let stored = try fixture.storedGrants(for: "conv_nope")
        #expect(stored.isEmpty)
    }

    // MARK: - Multi-grant projection

    @Test("Grant: publishes the union of existing and new grants")
    func grantPublishesUnion() async throws {
        let fixture = Fixture()
        defer { fixture.cleanup() }

        let first = try fixture.seedConnection(id: "conn_a", serviceId: "googlecalendar")
        let second = try fixture.seedConnection(id: "conn_b", serviceId: "googledrive")
        let conversationId = "conv_multi"
        try fixture.seedConversation(id: conversationId)

        try await fixture.writer.grantConnection(first.id, to: conversationId, grantedToInboxId: "agent-1")
        try await fixture.writer.grantConnection(second.id, to: conversationId, grantedToInboxId: "agent-1")

        let stored = try fixture.storedGrants(for: conversationId)
        #expect(stored.count == 2)

        #expect(fixture.profileWriter.publishedMetadata.count == 2)
        let lastPublish = try #require(fixture.profileWriter.publishedMetadata.last)
        let metadata = try #require(lastPublish.metadata)
        guard case .string(let grantsJson) = try #require(metadata["connections"]) else {
            Issue.record("connections entry was not a string")
            return
        }
        let payload = try CloudConnectionsMetadataPayload.fromJsonString(grantsJson)
        #expect(payload.grants.count == 2)
        let serviceIds = Set(payload.grants.map(\.service))
        #expect(serviceIds == ["googlecalendar", "googledrive"])
    }

    // MARK: - Backend grant push

    @Test("Grant: pushes one backend consent record and stores the returned id")
    func grantPushesBackendGrantAndStoresId() async throws {
        let recordingClient = RecordingGrantAPIClient()
        let fixture = Fixture(apiClient: recordingClient)
        defer { fixture.cleanup() }

        let connection = try fixture.seedConnection()
        let conversationId = "conv_backend"
        try fixture.seedConversation(id: conversationId)

        try await fixture.writer.grantConnection(connection.id, to: conversationId, grantedToInboxId: "agent-1")

        #expect(recordingClient.createCalls.count == 1)
        let call = try #require(recordingClient.createCalls.first)
        #expect(call.ownerInboxId == "mock-inbox-id")
        #expect(call.granteeInboxId == "agent-1")
        #expect(call.conversationId == conversationId)
        #expect(call.toolkit == connection.serviceId)
        #expect(call.connectionId == connection.composioConnectionId)

        let stored = try fixture.storedGrants(for: conversationId)
        #expect(stored.first?.backendGrantId == "backend-grant-1")
    }

    @Test("Grant: backend push failure keeps the local grant with a nil backend id")
    func grantSurvivesBackendPushFailure() async throws {
        let recordingClient = RecordingGrantAPIClient()
        struct PushFailure: Error {}
        recordingClient.createError = PushFailure()
        let fixture = Fixture(apiClient: recordingClient)
        defer { fixture.cleanup() }

        let connection = try fixture.seedConnection()
        let conversationId = "conv_backend_fail"
        try fixture.seedConversation(id: conversationId)

        try await fixture.writer.grantConnection(connection.id, to: conversationId, grantedToInboxId: "agent-1")

        let stored = try fixture.storedGrants(for: conversationId)
        #expect(stored.count == 1, "local grant should stand when the backend push fails")
        #expect(stored.first?.backendGrantId == nil)
    }

    @Test("Revoke: revokes the backend consent record when an id is stored")
    func revokeRevokesBackendGrant() async throws {
        let recordingClient = RecordingGrantAPIClient()
        let fixture = Fixture(apiClient: recordingClient)
        defer { fixture.cleanup() }

        let connection = try fixture.seedConnection()
        let conversationId = "conv_backend_rev"
        try fixture.seedConversation(id: conversationId)
        try fixture.seedGrant(
            connectionId: connection.id,
            conversationId: conversationId,
            serviceId: connection.serviceId,
            backendGrantId: "backend-grant-42"
        )

        try await fixture.writer.revokeGrant(connectionId: connection.id, from: conversationId, grantedToInboxId: "agent-1")

        #expect(recordingClient.revokeCalls == ["backend-grant-42"])
    }

    @Test("Revoke: skips the backend call when no backend id is stored")
    func revokeSkipsBackendWithoutId() async throws {
        let recordingClient = RecordingGrantAPIClient()
        let fixture = Fixture(apiClient: recordingClient)
        defer { fixture.cleanup() }

        let connection = try fixture.seedConnection()
        let conversationId = "conv_backend_skip"
        try fixture.seedConversation(id: conversationId)
        try fixture.seedGrant(
            connectionId: connection.id,
            conversationId: conversationId,
            serviceId: connection.serviceId
        )

        try await fixture.writer.revokeGrant(connectionId: connection.id, from: conversationId, grantedToInboxId: "agent-1")

        #expect(recordingClient.revokeCalls.isEmpty)
    }
}

/// Records backend grant push/revoke calls made by `CloudConnectionGrantWriter`
/// so tests can assert the consent records sent to the server.
private final class RecordingGrantAPIClient: TestStubAPIClient {
    struct CreateCall: Sendable {
        let ownerInboxId: String
        let granteeInboxId: String
        let conversationId: String
        let toolkit: String
        let connectionId: String?
    }

    var createCalls: [CreateCall] = []
    var revokeCalls: [String] = []
    var createError: Error?

    override func createConnectionGrant(
        ownerInboxId: String,
        granteeInboxId: String,
        conversationId: String,
        toolkit: String,
        connectionId: String?
    ) async throws -> CloudConnectionsAPI.CreateGrantResponse {
        if let createError {
            throw createError
        }
        createCalls.append(CreateCall(
            ownerInboxId: ownerInboxId,
            granteeInboxId: granteeInboxId,
            conversationId: conversationId,
            toolkit: toolkit,
            connectionId: connectionId
        ))
        return CloudConnectionsAPI.CreateGrantResponse(id: "backend-grant-\(createCalls.count)")
    }

    override func revokeConnectionGrant(id: String) async throws {
        revokeCalls.append(id)
    }
}
