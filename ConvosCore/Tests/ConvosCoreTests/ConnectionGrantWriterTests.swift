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
        let metadataWriter: MockProfileMetadataWriter
        let writer: CloudConnectionGrantWriter

        init(inboxId: String = "mock-inbox-id", apiClient: (any ConvosAPIClientProtocol)? = nil) {
            let databaseManager = MockDatabaseManager.makeTestDatabase()
            let metadataWriter = MockProfileMetadataWriter()
            let mockClient = MockXMTPClientProvider(inboxId: inboxId)
            let sessionStateManager = MockSessionStateManager(mockClient: mockClient, mockAPIClient: apiClient)
            self.databaseManager = databaseManager
            self.sessionStateManager = sessionStateManager
            self.metadataWriter = metadataWriter
            self.writer = CloudConnectionGrantWriter(
                sessionStateManager: sessionStateManager,
                databaseWriter: databaseManager.dbWriter,
                databaseReader: databaseManager.dbReader,
                profileMetadataWriter: metadataWriter,
                servicesStore: Self.makeServicesStore(apiClient: apiClient)
            )
        }

        /// Catalog reads go through the same (stubbed) API client the push
        /// uses, mirroring production wiring. Fixtures without a client get an
        /// empty catalog: every push takes the legacy whole-toolkit path.
        private static func makeServicesStore(
            apiClient: (any ConvosAPIClientProtocol)?
        ) -> ConnectionServicesStore {
            guard let apiClient else {
                return ConnectionServicesStore(fetchServices: {
                    CloudConnectionsAPI.ServicesResponse(services: [])
                })
            }
            return ConnectionServicesStore(fetchServices: {
                try await apiClient.getConnectionServices()
            })
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

        #expect(fixture.metadataWriter.updates.count == 1)
        let published = try #require(fixture.metadataWriter.updates.first)
        #expect(published.conversationId == conversationId)
        let metadata = published.metadata
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
        fixture.metadataWriter.updateError = PublishFailure()

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
        #expect(fixture.metadataWriter.updates.isEmpty)
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
        #expect(fixture.metadataWriter.updates.isEmpty)
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
        #expect(fixture.metadataWriter.updates.count == 1)
        let published = try #require(fixture.metadataWriter.updates.first)
        #expect(published.conversationId == conversationId)
        // With no remaining grants the closure removes the connections key, so
        // the merged map is empty (the writer collapses that to nil downstream).
        #expect(published.metadata.isEmpty)
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
        fixture.metadataWriter.updateError = PublishFailure()

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

        #expect(fixture.metadataWriter.updates.isEmpty)
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

        #expect(fixture.metadataWriter.updates.count == 2)
        let lastPublish = try #require(fixture.metadataWriter.updates.last)
        let metadata = lastPublish.metadata
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
        // No catalog entry for the service: the writer omits bundleIds and
        // serviceVersion, which the backend treats as a legacy whole-toolkit
        // grant. The legacy `actions` and `connectionId` fields are gone from
        // the API surface entirely.
        #expect(call.bundleIds == nil)
        #expect(call.serviceVersion == nil)

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

    @Test("Revoke: revokes the backend grant by natural key when a backend id is stored")
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

        // The natural-key revoke is the primary path; the unreliable by-id DELETE
        // is no longer used.
        #expect(recordingClient.revokeCalls.isEmpty)
        #expect(recordingClient.naturalKeyRevokeCalls == [
            .init(toolkit: connection.serviceId, conversationId: conversationId, granteeInboxId: "agent-1"),
        ])
    }

    @Test("Revoke: still revokes the backend grant by natural key when no backend id is stored")
    func revokeUsesNaturalKeyWithoutStoredId() async throws {
        let recordingClient = RecordingGrantAPIClient()
        let fixture = Fixture(apiClient: recordingClient)
        defer { fixture.cleanup() }

        let connection = try fixture.seedConnection()
        let conversationId = "conv_backend_natural"
        try fixture.seedConversation(id: conversationId)
        try fixture.seedGrant(
            connectionId: connection.id,
            conversationId: conversationId,
            serviceId: connection.serviceId
        )

        try await fixture.writer.revokeGrant(connectionId: connection.id, from: conversationId, grantedToInboxId: "agent-1")

        // Natural-key revoke succeeds even though no backendGrantId was ever
        // stored -- this is the reliability fix over the by-id DELETE.
        #expect(recordingClient.revokeCalls.isEmpty)
        #expect(recordingClient.naturalKeyRevokeCalls == [
            .init(toolkit: connection.serviceId, conversationId: conversationId, granteeInboxId: "agent-1"),
        ])
    }

    // MARK: - Bundle-scoped grants

    /// Catalog fixture for the default `seedConnection` service
    /// ("googlecalendar").
    private static func calendarCatalog(
        version: Int,
        bundleIds: [String]
    ) -> [CloudConnectionsAPI.ServiceConfig] {
        [
            CloudConnectionsAPI.ServiceConfig(
                id: "googlecalendar",
                composioSlug: "googlecalendar",
                version: version,
                displayName: .init(values: ["en": "Google Calendar"]),
                bundles: bundleIds.map { id in
                    CloudConnectionsAPI.ServiceBundle(
                        id: id,
                        title: .init(values: ["en": id]),
                        description: .init(values: ["en": "About \(id)"]),
                        defaultEnabled: false
                    )
                }
            ),
        ]
    }

    @Test("Grant: explicit bundle selection is pushed with the catalog service version")
    func grantPushesExplicitBundleSelection() async throws {
        let recordingClient = RecordingGrantAPIClient()
        recordingClient.servicesCatalogQueue = [
            Self.calendarCatalog(version: 2, bundleIds: ["calendar.events", "calendar.events.read"]),
        ]
        let fixture = Fixture(apiClient: recordingClient)
        defer { fixture.cleanup() }

        let connection = try fixture.seedConnection()
        let conversationId = "conv_bundles"
        try fixture.seedConversation(id: conversationId)

        try await fixture.writer.grantConnection(
            connection.id,
            to: conversationId,
            grantedToInboxId: "agent-1",
            bundleIds: ["calendar.events"]
        )

        #expect(recordingClient.createCalls.count == 1)
        let call = try #require(recordingClient.createCalls.first)
        #expect(call.bundleIds == ["calendar.events"])
        #expect(call.serviceVersion == 2)

        let stored = try fixture.storedGrants(for: conversationId)
        #expect(stored.first?.bundleIds == ["calendar.events"])
        #expect(stored.first?.serviceVersion == 2)
        #expect(stored.first?.backendGrantId == "backend-grant-1")
    }

    @Test("Grant: no explicit selection grants every catalog bundle for the service")
    func grantWithoutSelectionGrantsAllCatalogBundles() async throws {
        let recordingClient = RecordingGrantAPIClient()
        recordingClient.servicesCatalogQueue = [
            Self.calendarCatalog(version: 5, bundleIds: ["calendar.events", "calendar.events.read"]),
        ]
        let fixture = Fixture(apiClient: recordingClient)
        defer { fixture.cleanup() }

        let connection = try fixture.seedConnection()
        let conversationId = "conv_bundles_all"
        try fixture.seedConversation(id: conversationId)

        try await fixture.writer.grantConnection(connection.id, to: conversationId, grantedToInboxId: "agent-1")

        #expect(recordingClient.createCalls.count == 1)
        let call = try #require(recordingClient.createCalls.first)
        #expect(call.bundleIds == ["calendar.events", "calendar.events.read"])
        #expect(call.serviceVersion == 5)

        let stored = try fixture.storedGrants(for: conversationId)
        #expect(stored.first?.bundleIds == ["calendar.events", "calendar.events.read"])
        #expect(stored.first?.serviceVersion == 5)
    }

    @Test("Grant: fails closed when the cataloged service lists no bundles and there is no selection")
    func grantFailsClosedWhenCatalogServiceHasNoBundles() async throws {
        let recordingClient = RecordingGrantAPIClient()
        recordingClient.servicesCatalogQueue = [
            Self.calendarCatalog(version: 4, bundleIds: []),
        ]
        let fixture = Fixture(apiClient: recordingClient)
        defer { fixture.cleanup() }

        let connection = try fixture.seedConnection()
        let conversationId = "conv_zero_bundles"
        try fixture.seedConversation(id: conversationId)

        try await fixture.writer.grantConnection(connection.id, to: conversationId, grantedToInboxId: "agent-1")

        // A cataloged service with zero bundles must not materialize an empty
        // bundleIds array: the backend's legacy path treats that as
        // whole-toolkit access. The push is skipped entirely.
        #expect(recordingClient.createCalls.isEmpty)
        let stored = try fixture.storedGrants(for: conversationId)
        #expect(stored.count == 1, "the local grant still stands, same as any push failure")
        #expect(stored.first?.backendGrantId == nil)
    }

    @Test("Grant: fails closed on an explicit empty selection — never pushed as whole-toolkit")
    func grantFailsClosedOnExplicitEmptySelection() async throws {
        let recordingClient = RecordingGrantAPIClient()
        recordingClient.servicesCatalogQueue = [
            Self.calendarCatalog(version: 4, bundleIds: []),
        ]
        let fixture = Fixture(apiClient: recordingClient)
        defer { fixture.cleanup() }

        let connection = try fixture.seedConnection()
        let conversationId = "conv_empty_selection"
        try fixture.seedConversation(id: conversationId)

        try await fixture.writer.grantConnection(
            connection.id,
            to: conversationId,
            grantedToInboxId: "agent-1",
            bundleIds: []
        )

        // An explicit empty selection means the user approved zero bundles;
        // pushing it would escalate to whole-toolkit access (the backend
        // treats an empty array as the legacy whole-toolkit path).
        #expect(recordingClient.createCalls.isEmpty)
        let stored = try fixture.storedGrants(for: conversationId)
        #expect(stored.first?.backendGrantId == nil)
    }

    @Test("Grant: explicit empty selection fails closed even for an uncataloged service")
    func grantFailsClosedOnExplicitEmptySelectionForUncatalogedService() async throws {
        let recordingClient = RecordingGrantAPIClient()
        // Empty catalog: the service is proven absent, the path that would
        // otherwise pass the selection through as-is.
        recordingClient.servicesCatalogQueue = []
        let fixture = Fixture(apiClient: recordingClient)
        defer { fixture.cleanup() }

        let connection = try fixture.seedConnection()
        let conversationId = "conv_empty_uncataloged"
        try fixture.seedConversation(id: conversationId)

        try await fixture.writer.grantConnection(
            connection.id,
            to: conversationId,
            grantedToInboxId: "agent-1",
            bundleIds: []
        )

        #expect(recordingClient.createCalls.isEmpty)
        let stored = try fixture.storedGrants(for: conversationId)
        #expect(stored.first?.backendGrantId == nil)
    }

    @Test("Grant: unknown_bundle refetches the catalog, drops unknown ids, and retries once")
    func grantRetriesOnceOnUnknownBundle() async throws {
        let recordingClient = RecordingGrantAPIClient()
        recordingClient.servicesCatalogQueue = [
            Self.calendarCatalog(version: 2, bundleIds: ["calendar.old", "calendar.events"]),
            Self.calendarCatalog(version: 3, bundleIds: ["calendar.events"]),
        ]
        recordingClient.createErrorQueue = [
            CloudConnectionsAPI.GrantError.unknownBundle(bundleId: "calendar.old"),
        ]
        let fixture = Fixture(apiClient: recordingClient)
        defer { fixture.cleanup() }

        let connection = try fixture.seedConnection()
        let conversationId = "conv_stale"
        try fixture.seedConversation(id: conversationId)

        try await fixture.writer.grantConnection(
            connection.id,
            to: conversationId,
            grantedToInboxId: "agent-1",
            bundleIds: ["calendar.old", "calendar.events"]
        )

        #expect(recordingClient.createCalls.count == 2)
        #expect(recordingClient.createCalls.first?.bundleIds == ["calendar.old", "calendar.events"])
        let retry = try #require(recordingClient.createCalls.last)
        #expect(retry.bundleIds == ["calendar.events"])
        #expect(retry.serviceVersion == 3)
        #expect(recordingClient.servicesFetchCount == 2)

        let stored = try fixture.storedGrants(for: conversationId)
        #expect(stored.first?.bundleIds == ["calendar.events"])
        #expect(stored.first?.serviceVersion == 3)
        #expect(stored.first?.backendGrantId == "backend-grant-2")
    }

    @Test("Grant: a second unknown_bundle rejection gives up — exactly one retry, no loop")
    func grantGivesUpAfterOneUnknownBundleRetry() async throws {
        let recordingClient = RecordingGrantAPIClient()
        recordingClient.servicesCatalogQueue = [
            Self.calendarCatalog(version: 2, bundleIds: ["calendar.events"]),
            Self.calendarCatalog(version: 3, bundleIds: ["calendar.events"]),
        ]
        recordingClient.createErrorQueue = [
            CloudConnectionsAPI.GrantError.unknownBundle(bundleId: "calendar.events"),
            CloudConnectionsAPI.GrantError.unknownBundle(bundleId: "calendar.events"),
        ]
        let fixture = Fixture(apiClient: recordingClient)
        defer { fixture.cleanup() }

        let connection = try fixture.seedConnection()
        let conversationId = "conv_stale_twice"
        try fixture.seedConversation(id: conversationId)

        try await fixture.writer.grantConnection(
            connection.id,
            to: conversationId,
            grantedToInboxId: "agent-1",
            bundleIds: ["calendar.events"]
        )

        // Two attempts (original + one retry), then the push is abandoned:
        // the local grant stands with no backend id, same as any push failure.
        #expect(recordingClient.createCalls.count == 2)
        let stored = try fixture.storedGrants(for: conversationId)
        #expect(stored.count == 1)
        #expect(stored.first?.backendGrantId == nil)
    }

    @Test("Grant: fails closed when the refreshed catalog knows none of the selected bundles")
    func grantFailsClosedWhenSelectionVanishesFromCatalog() async throws {
        let recordingClient = RecordingGrantAPIClient()
        recordingClient.servicesCatalogQueue = [
            Self.calendarCatalog(version: 2, bundleIds: ["calendar.old"]),
            Self.calendarCatalog(version: 3, bundleIds: ["calendar.events"]),
        ]
        recordingClient.createErrorQueue = [
            CloudConnectionsAPI.GrantError.unknownBundle(bundleId: "calendar.old"),
        ]
        let fixture = Fixture(apiClient: recordingClient)
        defer { fixture.cleanup() }

        let connection = try fixture.seedConnection()
        let conversationId = "conv_vanished"
        try fixture.seedConversation(id: conversationId)

        try await fixture.writer.grantConnection(
            connection.id,
            to: conversationId,
            grantedToInboxId: "agent-1",
            bundleIds: ["calendar.old"]
        )

        // No retry: pushing an empty bundle set would escalate to whole-toolkit
        // access, strictly more than the user approved.
        #expect(recordingClient.createCalls.count == 1)
        let stored = try fixture.storedGrants(for: conversationId)
        #expect(stored.first?.backendGrantId == nil)
    }

    @Test("Grant: catalog outage with no explicit selection fails closed — no whole-toolkit push")
    func grantFailsClosedOnCatalogOutageWithoutSelection() async throws {
        struct CatalogDown: Error {}
        let recordingClient = RecordingGrantAPIClient()
        recordingClient.servicesError = CatalogDown()
        let fixture = Fixture(apiClient: recordingClient)
        defer { fixture.cleanup() }

        let connection = try fixture.seedConnection()
        let conversationId = "conv_outage"
        try fixture.seedConversation(id: conversationId)

        try await fixture.writer.grantConnection(connection.id, to: conversationId, grantedToInboxId: "agent-1")

        // An unreachable catalog must not be conflated with "service not in
        // catalog": omitting bundleIds here could grant whole-toolkit access
        // for a service that IS cataloged. The push is skipped entirely.
        #expect(recordingClient.createCalls.isEmpty)
        let stored = try fixture.storedGrants(for: conversationId)
        #expect(stored.count == 1, "the local grant still stands, same as any push failure")
        #expect(stored.first?.backendGrantId == nil)
    }

    @Test("Grant: catalog outage with an explicit selection pushes it unfiltered, no version")
    func grantPushesExplicitSelectionDuringCatalogOutage() async throws {
        struct CatalogDown: Error {}
        let recordingClient = RecordingGrantAPIClient()
        recordingClient.servicesError = CatalogDown()
        let fixture = Fixture(apiClient: recordingClient)
        defer { fixture.cleanup() }

        let connection = try fixture.seedConnection()
        let conversationId = "conv_outage_explicit"
        try fixture.seedConversation(id: conversationId)

        try await fixture.writer.grantConnection(
            connection.id,
            to: conversationId,
            grantedToInboxId: "agent-1",
            bundleIds: ["calendar.events"]
        )

        // The user's explicit picks are safe to transmit — the backend
        // validates them against its own catalog.
        #expect(recordingClient.createCalls.count == 1)
        let call = try #require(recordingClient.createCalls.first)
        #expect(call.bundleIds == ["calendar.events"])
        #expect(call.serviceVersion == nil)
    }

    @Test("Grant: the unknown_bundle retry never widens a nil-selection grant past the first attempt")
    func grantRetryNeverWidensScope() async throws {
        let recordingClient = RecordingGrantAPIClient()
        recordingClient.servicesCatalogQueue = [
            Self.calendarCatalog(version: 2, bundleIds: ["calendar.events"]),
            Self.calendarCatalog(version: 3, bundleIds: ["calendar.events", "calendar.brand.new"]),
        ]
        recordingClient.createErrorQueue = [
            CloudConnectionsAPI.GrantError.unknownBundle(bundleId: "calendar.events"),
        ]
        let fixture = Fixture(apiClient: recordingClient)
        defer { fixture.cleanup() }

        let connection = try fixture.seedConnection()
        let conversationId = "conv_no_widen"
        try fixture.seedConversation(id: conversationId)

        try await fixture.writer.grantConnection(connection.id, to: conversationId, grantedToInboxId: "agent-1")

        // The nil selection materialized to the v2 catalog (["calendar.events"])
        // on the first attempt. The retry intersects THAT with the refreshed
        // catalog — it must not pick up v3's extra bundle.
        #expect(recordingClient.createCalls.count == 2)
        #expect(recordingClient.createCalls.first?.bundleIds == ["calendar.events"])
        let retry = try #require(recordingClient.createCalls.last)
        #expect(retry.bundleIds == ["calendar.events"])
        #expect(retry.bundleIds?.contains("calendar.brand.new") == false)
        #expect(retry.serviceVersion == 3)

        let stored = try fixture.storedGrants(for: conversationId)
        #expect(stored.first?.bundleIds == ["calendar.events"])
    }
}

/// Records backend grant push/revoke calls made by `CloudConnectionGrantWriter`
/// so tests can assert the consent records sent to the server. Also serves the
/// services catalog: `servicesCatalogQueue` is consumed one response per fetch
/// (the last entry repeats), so tests can model a stale catalog that changes
/// across the unknown_bundle refetch.
private final class RecordingGrantAPIClient: TestStubAPIClient {
    struct CreateCall: Sendable {
        let ownerInboxId: String
        let granteeInboxId: String
        let conversationId: String
        let toolkit: String
        let bundleIds: [String]?
        let serviceVersion: Int?
    }

    struct NaturalKeyRevokeCall: Sendable, Equatable {
        let toolkit: String
        let conversationId: String?
        let granteeInboxId: String?
    }

    var createCalls: [CreateCall] = []
    var revokeCalls: [String] = []
    var naturalKeyRevokeCalls: [NaturalKeyRevokeCall] = []
    var createError: Error?
    /// Thrown once per entry (after the attempt is recorded), then discarded —
    /// models a 400 the server rejects before a later attempt succeeds.
    var createErrorQueue: [Error] = []
    var servicesCatalogQueue: [[CloudConnectionsAPI.ServiceConfig]] = []
    var servicesFetchCount: Int = 0
    /// When set, every catalog fetch fails — models a backend/network outage.
    var servicesError: Error?

    override func getConnectionServices() async throws -> CloudConnectionsAPI.ServicesResponse {
        servicesFetchCount += 1
        if let servicesError {
            throw servicesError
        }
        guard let catalog = servicesCatalogQueue.first else {
            return CloudConnectionsAPI.ServicesResponse(services: [])
        }
        if servicesCatalogQueue.count > 1 {
            servicesCatalogQueue.removeFirst()
        }
        return CloudConnectionsAPI.ServicesResponse(services: catalog)
    }

    override func createConnectionGrant(
        ownerInboxId: String,
        granteeInboxId: String,
        conversationId: String,
        toolkit: String,
        bundleIds: [String]?,
        serviceVersion: Int?
    ) async throws -> CloudConnectionsAPI.CreateGrantResponse {
        createCalls.append(CreateCall(
            ownerInboxId: ownerInboxId,
            granteeInboxId: granteeInboxId,
            conversationId: conversationId,
            toolkit: toolkit,
            bundleIds: bundleIds,
            serviceVersion: serviceVersion
        ))
        if let createError {
            throw createError
        }
        if !createErrorQueue.isEmpty {
            throw createErrorQueue.removeFirst()
        }
        return CloudConnectionsAPI.CreateGrantResponse(id: "backend-grant-\(createCalls.count)")
    }

    override func revokeConnectionGrant(id: String) async throws {
        revokeCalls.append(id)
    }

    override func revokeConnectionGrantByNaturalKey(
        toolkit: String,
        conversationId: String?,
        granteeInboxId: String?
    ) async throws -> Int {
        naturalKeyRevokeCalls.append(NaturalKeyRevokeCall(
            toolkit: toolkit,
            conversationId: conversationId,
            granteeInboxId: granteeInboxId
        ))
        return 1
    }
}
