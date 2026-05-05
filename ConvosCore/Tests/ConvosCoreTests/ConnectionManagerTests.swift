import ConvosConnections
@testable import ConvosCore
import Foundation
import GRDB
import Testing

@Suite("CloudConnectionManager Tests", .serialized)
struct ConnectionManagerTests {
    // MARK: - H1: refreshConnections() delta update

    @Test("refreshConnections preserves existing grants when server returns the same connection")
    func refreshPreservesGrants() async throws {
        let fixtures = try await makeTestFixtures()
        let apiClient = StubAPIClient()
        let grantWriter = RecordingGrantWriter()

        let manager = makeManager(fixtures: fixtures, apiClient: apiClient, grantWriter: grantWriter)

        let connectionId = "conn-1"
        let conversationId = "convo-1"

        try await fixtures.dbWriter.write { db in
            try makeDBConversation(id: conversationId).insert(db)
            try makeDBConnection(id: connectionId).insert(db)
            try DBCloudConnectionGrant(
                connectionId: connectionId,
                conversationId: conversationId,
                serviceId: "google_calendar",
                grantedAt: Date()
            ).insert(db)
        }

        apiClient.stubbedConnections = [
            makeConnectionResponse(connectionId: connectionId, serviceId: "google_calendar")
        ]

        _ = try await manager.refreshConnections()

        let grantCount = try await fixtures.dbReader.read { db in
            try DBCloudConnectionGrant.fetchCount(db)
        }
        #expect(grantCount == 1, "Delta update must not cascade-delete grants for connections the server still returns")

        let connectionCount = try await fixtures.dbReader.read { db in
            try DBCloudConnection.fetchCount(db)
        }
        #expect(connectionCount == 1)
    }

    @Test("refreshConnections removes local rows no longer returned by the server")
    func refreshDeletesMissingConnections() async throws {
        let fixtures = try await makeTestFixtures()
        let apiClient = StubAPIClient()
        let grantWriter = RecordingGrantWriter()

        let manager = makeManager(fixtures: fixtures, apiClient: apiClient, grantWriter: grantWriter)

        try await fixtures.dbWriter.write { db in
            try makeDBConnection(id: "conn-stale").insert(db)
            try makeDBConnection(id: "conn-keep").insert(db)
        }

        apiClient.stubbedConnections = [
            makeConnectionResponse(connectionId: "conn-keep", serviceId: "google_calendar")
        ]

        _ = try await manager.refreshConnections()

        let remaining = try await fixtures.dbReader.read { db in
            try DBCloudConnection.fetchAll(db).map(\.id).sorted()
        }
        #expect(remaining == ["conn-keep"], "Delta update must drop rows the server no longer returns")
    }

    @Test("refreshConnections preserves the existing connectedAt for rows the server still returns")
    func refreshPreservesConnectedAt() async throws {
        let fixtures = try await makeTestFixtures()
        let apiClient = StubAPIClient()
        let grantWriter = RecordingGrantWriter()

        let manager = makeManager(fixtures: fixtures, apiClient: apiClient, grantWriter: grantWriter)

        let connectionId = "conn-1"
        let originalConnectedAt = Date(timeIntervalSince1970: 1_700_000_000)

        try await fixtures.dbWriter.write { db in
            try DBCloudConnection(
                id: connectionId,
                serviceId: "google_calendar",
                serviceName: "Google Calendar",
                provider: CloudConnectionProvider.composio.rawValue,
                composioEntityId: "entity-\(connectionId)",
                composioConnectionId: "ca-\(connectionId)",
                status: CloudConnectionStatus.active.rawValue,
                connectedAt: originalConnectedAt
            ).insert(db)
        }

        apiClient.stubbedConnections = [
            makeConnectionResponse(connectionId: connectionId, serviceId: "google_calendar", status: "EXPIRED")
        ]

        let returned = try await manager.refreshConnections()

        #expect(returned.first?.connectedAt == originalConnectedAt,
                "Refresh must not overwrite an existing connectedAt with Date()")

        let stored = try await fixtures.dbReader.read { db in
            try DBCloudConnection.fetchOne(db, key: connectionId)
        }
        #expect(stored?.connectedAt == originalConnectedAt,
                "Database must preserve the original connectedAt across refresh")
        #expect(stored?.status == CloudConnectionStatus.expired.rawValue,
                "Refresh should still apply status updates from the server")
    }

    @Test("refreshConnections stamps Date() on brand-new rows")
    func refreshStampsNewRowsWithNow() async throws {
        let fixtures = try await makeTestFixtures()
        let apiClient = StubAPIClient()
        let grantWriter = RecordingGrantWriter()

        let manager = makeManager(fixtures: fixtures, apiClient: apiClient, grantWriter: grantWriter)

        let before = Date()
        apiClient.stubbedConnections = [
            makeConnectionResponse(connectionId: "conn-new", serviceId: "google_calendar")
        ]

        let returned = try await manager.refreshConnections()
        let after = Date()

        let stampedAt = try #require(returned.first?.connectedAt)
        #expect(stampedAt >= before && stampedAt <= after,
                "A brand-new connection should get Date() as its connectedAt")
    }

    @Test("refreshConnections upserts status changes without touching grants")
    func refreshUpdatesStatus() async throws {
        let fixtures = try await makeTestFixtures()
        let apiClient = StubAPIClient()
        let grantWriter = RecordingGrantWriter()

        let manager = makeManager(fixtures: fixtures, apiClient: apiClient, grantWriter: grantWriter)

        let connectionId = "conn-1"
        let conversationId = "convo-1"

        try await fixtures.dbWriter.write { db in
            try makeDBConversation(id: conversationId).insert(db)
            try makeDBConnection(id: connectionId, status: CloudConnectionStatus.active.rawValue).insert(db)
            try DBCloudConnectionGrant(
                connectionId: connectionId,
                conversationId: conversationId,
                serviceId: "google_calendar",
                grantedAt: Date()
            ).insert(db)
        }

        apiClient.stubbedConnections = [
            makeConnectionResponse(connectionId: connectionId, serviceId: "google_calendar", status: "EXPIRED")
        ]

        _ = try await manager.refreshConnections()

        let storedStatus = try await fixtures.dbReader.read { db in
            try DBCloudConnection.fetchOne(db, key: connectionId)?.status
        }
        #expect(storedStatus == CloudConnectionStatus.expired.rawValue)

        let grantCount = try await fixtures.dbReader.read { db in
            try DBCloudConnectionGrant.fetchCount(db)
        }
        #expect(grantCount == 1)
    }

    @Test("refreshConnections posts revoked event and clears resolver for orphaned connections")
    func refreshOrphanedConnectionsClearsState() async throws {
        let fixtures = try await makeTestFixtures()
        let apiClient = StubAPIClient()
        let grantWriter = RecordingGrantWriter()
        let eventWriter = RecordingEventWriter()
        let resolver = RecordingResolver()

        let manager = makeManager(
            fixtures: fixtures,
            apiClient: apiClient,
            grantWriter: grantWriter,
            eventWriter: eventWriter,
            resolver: resolver
        )

        let staleId = "conn-stale"
        let keepId = "conn-keep"

        try await fixtures.dbWriter.write { db in
            try makeDBConversation(id: "convo-a").insert(db)
            try makeDBConversation(id: "convo-b").insert(db)
            try makeDBConnection(id: staleId, serviceId: "google_calendar").insert(db)
            try makeDBConnection(id: keepId, serviceId: "google_calendar").insert(db)
            try DBCloudConnectionGrant(
                connectionId: staleId,
                conversationId: "convo-a",
                serviceId: "google_calendar",
                grantedAt: Date()
            ).insert(db)
            try DBCloudConnectionGrant(
                connectionId: staleId,
                conversationId: "convo-b",
                serviceId: "google_calendar",
                grantedAt: Date()
            ).insert(db)
            // Grant on a kept connection — must not trigger any revoke side-effects.
            try DBCloudConnectionGrant(
                connectionId: keepId,
                conversationId: "convo-a",
                serviceId: "google_calendar",
                grantedAt: Date()
            ).insert(db)
        }

        apiClient.stubbedConnections = [
            makeConnectionResponse(connectionId: keepId, serviceId: "google_calendar")
        ]

        _ = try await manager.refreshConnections()

        let revokedEvents = await eventWriter.revokedEvents()
        #expect(revokedEvents.count == 2, "Each conversation that referenced the orphan must get a revoked event")
        #expect(Set(revokedEvents.map(\.conversationId)) == ["convo-a", "convo-b"])
        #expect(revokedEvents.allSatisfy { $0.providerId == "composio.google_calendar" })
        #expect(revokedEvents.allSatisfy { $0.capability == nil })

        let cleared = await resolver.removedProviders()
        #expect(cleared == [ProviderID(rawValue: "composio.google_calendar")],
                "Resolver must be cleared exactly once per orphaned provider")
    }

    // MARK: - H7: disconnect() republishes metadata

    @Test("disconnect republishes metadata for every conversation that referenced the connection")
    func disconnectRepublishesMetadata() async throws {
        let fixtures = try await makeTestFixtures()
        let apiClient = StubAPIClient()
        let grantWriter = RecordingGrantWriter()

        let manager = makeManager(fixtures: fixtures, apiClient: apiClient, grantWriter: grantWriter)

        let connectionId = "conn-1"

        try await fixtures.dbWriter.write { db in
            try makeDBConversation(id: "convo-a").insert(db)
            try makeDBConversation(id: "convo-b").insert(db)
            try makeDBConnection(id: connectionId).insert(db)
            try makeDBConnection(id: "conn-other").insert(db)

            try DBCloudConnectionGrant(
                connectionId: connectionId,
                conversationId: "convo-a",
                serviceId: "google_calendar",
                grantedAt: Date()
            ).insert(db)
            try DBCloudConnectionGrant(
                connectionId: connectionId,
                conversationId: "convo-b",
                serviceId: "google_calendar",
                grantedAt: Date()
            ).insert(db)
            // Unrelated grant for a different connection — must not trigger republish.
            try DBCloudConnectionGrant(
                connectionId: "conn-other",
                conversationId: "convo-a",
                serviceId: "google_calendar",
                grantedAt: Date()
            ).insert(db)
        }

        try await manager.disconnect(connectionId: connectionId)

        #expect(apiClient.revokedConnectionIds == [connectionId])

        let revokedPairs = await grantWriter.revokedGrants()
        let expected: Set<String> = ["convo-a", "convo-b"]
        #expect(Set(revokedPairs.map(\.conversationId)) == expected)
        #expect(revokedPairs.allSatisfy { $0.connectionId == connectionId })

        let connectionRow = try await fixtures.dbReader.read { db in
            try DBCloudConnection.fetchOne(db, key: connectionId)
        }
        #expect(connectionRow == nil, "Local connection row must still be deleted after republish")
    }

    @Test("disconnect with no grants does not call the grant writer")
    func disconnectWithNoGrantsSkipsRepublish() async throws {
        let fixtures = try await makeTestFixtures()
        let apiClient = StubAPIClient()
        let grantWriter = RecordingGrantWriter()

        let manager = makeManager(fixtures: fixtures, apiClient: apiClient, grantWriter: grantWriter)

        try await fixtures.dbWriter.write { db in
            try makeDBConnection(id: "conn-1").insert(db)
        }

        try await manager.disconnect(connectionId: "conn-1")

        let revoked = await grantWriter.revokedGrants()
        #expect(revoked.isEmpty)

        let connectionRow = try await fixtures.dbReader.read { db in
            try DBCloudConnection.fetchOne(db, key: "conn-1")
        }
        #expect(connectionRow == nil)
    }

    @Test("disconnect posts ConnectionEvent.revoked in every affected conversation")
    func disconnectPostsRevokedEvent() async throws {
        let fixtures = try await makeTestFixtures()
        let apiClient = StubAPIClient()
        let grantWriter = RecordingGrantWriter()
        let eventWriter = RecordingEventWriter()
        let resolver = RecordingResolver()

        let manager = makeManager(
            fixtures: fixtures,
            apiClient: apiClient,
            grantWriter: grantWriter,
            eventWriter: eventWriter,
            resolver: resolver
        )

        let connectionId = "conn-1"

        try await fixtures.dbWriter.write { db in
            try makeDBConversation(id: "convo-a").insert(db)
            try makeDBConversation(id: "convo-b").insert(db)
            try makeDBConnection(id: connectionId, serviceId: "google_calendar").insert(db)

            try DBCloudConnectionGrant(
                connectionId: connectionId,
                conversationId: "convo-a",
                serviceId: "google_calendar",
                grantedAt: Date()
            ).insert(db)
            try DBCloudConnectionGrant(
                connectionId: connectionId,
                conversationId: "convo-b",
                serviceId: "google_calendar",
                grantedAt: Date()
            ).insert(db)
        }

        try await manager.disconnect(connectionId: connectionId)

        let revokedEvents = await eventWriter.revokedEvents()
        #expect(revokedEvents.count == 2)
        #expect(Set(revokedEvents.map(\.conversationId)) == ["convo-a", "convo-b"])
        #expect(revokedEvents.allSatisfy { $0.providerId == "composio.google_calendar" })
        // App-level disconnect spans every verb, so capability stays nil.
        #expect(revokedEvents.allSatisfy { $0.capability == nil })
    }

    @Test("disconnect clears the provider from every CapabilityResolution")
    func disconnectClearsResolutions() async throws {
        let fixtures = try await makeTestFixtures()
        let apiClient = StubAPIClient()
        let grantWriter = RecordingGrantWriter()
        let resolver = RecordingResolver()

        let manager = makeManager(
            fixtures: fixtures,
            apiClient: apiClient,
            grantWriter: grantWriter,
            resolver: resolver
        )

        let connectionId = "conn-1"

        try await fixtures.dbWriter.write { db in
            try makeDBConversation(id: "convo-a").insert(db)
            try makeDBConnection(id: connectionId, serviceId: "google_calendar").insert(db)
            try DBCloudConnectionGrant(
                connectionId: connectionId,
                conversationId: "convo-a",
                serviceId: "google_calendar",
                grantedAt: Date()
            ).insert(db)
        }

        try await manager.disconnect(connectionId: connectionId)

        let cleared = await resolver.removedProviders()
        #expect(cleared == [ProviderID(rawValue: "composio.google_calendar")])
    }

    @Test("disconnect tolerates event writer and resolver failures")
    func disconnectTolerantOfEventOrResolverFailure() async throws {
        let fixtures = try await makeTestFixtures()
        let apiClient = StubAPIClient()
        let grantWriter = RecordingGrantWriter()
        let eventWriter = RecordingEventWriter()
        await eventWriter.setShouldThrow(true)
        let resolver = RecordingResolver()
        await resolver.setShouldThrow(true)

        let manager = makeManager(
            fixtures: fixtures,
            apiClient: apiClient,
            grantWriter: grantWriter,
            eventWriter: eventWriter,
            resolver: resolver
        )

        let connectionId = "conn-1"

        try await fixtures.dbWriter.write { db in
            try makeDBConversation(id: "convo-a").insert(db)
            try makeDBConnection(id: connectionId, serviceId: "google_calendar").insert(db)
            try DBCloudConnectionGrant(
                connectionId: connectionId,
                conversationId: "convo-a",
                serviceId: "google_calendar",
                grantedAt: Date()
            ).insert(db)
        }

        try await manager.disconnect(connectionId: connectionId)

        let connectionRow = try await fixtures.dbReader.read { db in
            try DBCloudConnection.fetchOne(db, key: connectionId)
        }
        #expect(connectionRow == nil, "Local connection row must still be deleted when side-effect writers throw")
    }

    @Test("disconnect still deletes the local row when the grant writer throws")
    func disconnectTolerantOfGrantWriterFailure() async throws {
        let fixtures = try await makeTestFixtures()
        let apiClient = StubAPIClient()
        let grantWriter = RecordingGrantWriter()
        await grantWriter.setShouldThrow(true)

        let manager = makeManager(fixtures: fixtures, apiClient: apiClient, grantWriter: grantWriter)

        let connectionId = "conn-1"

        try await fixtures.dbWriter.write { db in
            try makeDBConversation(id: "convo-a").insert(db)
            try makeDBConnection(id: connectionId).insert(db)
            try DBCloudConnectionGrant(
                connectionId: connectionId,
                conversationId: "convo-a",
                serviceId: "google_calendar",
                grantedAt: Date()
            ).insert(db)
        }

        try await manager.disconnect(connectionId: connectionId)

        let connectionRow = try await fixtures.dbReader.read { db in
            try DBCloudConnection.fetchOne(db, key: connectionId)
        }
        #expect(connectionRow == nil)
    }
}

// MARK: - Helpers

private extension ConnectionManagerTests {
    struct TestFixtures {
        let dbWriter: any DatabaseWriter
        let dbReader: any DatabaseReader
    }

    func makeTestFixtures() async throws -> TestFixtures {
        let dbManager = MockDatabaseManager.makeTestDatabase()
        return TestFixtures(dbWriter: dbManager.dbWriter, dbReader: dbManager.dbReader)
    }

    func makeManager(
        fixtures: TestFixtures,
        apiClient: any ConvosAPIClientProtocol,
        grantWriter: RecordingGrantWriter,
        eventWriter: RecordingEventWriter? = nil,
        resolver: RecordingResolver? = nil
    ) -> CloudConnectionManager {
        CloudConnectionManager(
            apiClient: apiClient,
            oauthProvider: StubOAuthSessionProvider(),
            databaseWriter: fixtures.dbWriter,
            callbackURLScheme: "convos",
            grantWriterProvider: { grantWriter },
            eventWriterProvider: { eventWriter },
            resolverProvider: { resolver }
        )
    }

    func makeDBConversation(id: String) -> DBConversation {
        DBConversation(
            id: id,
            clientConversationId: id,
            inviteTag: "invite-\(id)",
            creatorId: "inbox-1",
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
    }

    func makeDBConnection(
        id: String,
        serviceId: String = "google_calendar",
        status: String = CloudConnectionStatus.active.rawValue
    ) -> DBCloudConnection {
        DBCloudConnection(
            id: id,
            serviceId: serviceId,
            serviceName: "Google Calendar",
            provider: CloudConnectionProvider.composio.rawValue,
            composioEntityId: "entity-\(id)",
            composioConnectionId: "ca-\(id)",
            status: status,
            connectedAt: Date()
        )
    }

    func makeConnectionResponse(
        connectionId: String,
        serviceId: String,
        status: String = "ACTIVE"
    ) -> CloudConnectionsAPI.ConnectionResponse {
        CloudConnectionsAPI.ConnectionResponse(
            connectionId: connectionId,
            serviceId: serviceId,
            serviceName: "Google Calendar",
            composioEntityId: "entity-\(connectionId)",
            composioConnectionId: "ca-\(connectionId)",
            status: status
        )
    }
}

// MARK: - Doubles

private final class StubAPIClient: ConvosAPIClientProtocol, @unchecked Sendable {
    var stubbedConnections: [CloudConnectionsAPI.ConnectionResponse] = []
    private(set) var revokedConnectionIds: [String] = []

    func request(for path: String, method: String, queryParameters: [String: String]?) throws -> URLRequest {
        guard let url = URL(string: "http://example.com") else {
            throw StubError.invalidURL
        }
        return URLRequest(url: url)
    }

    func registerDevice(deviceId: String, pushToken: String?) async throws {}

    func authenticate(appCheckToken: String, retryCount: Int) async throws -> String {
        "stub-jwt"
    }

    func uploadAttachment(data: Data, filename: String, contentType: String, acl: String) async throws -> String {
        "https://example.com/\(filename)"
    }

    func uploadAttachmentAndExecute(
        data: Data,
        filename: String,
        afterUpload: @escaping (String) async throws -> Void
    ) async throws -> String {
        let url = "https://example.com/\(filename)"
        try await afterUpload(url)
        return url
    }

    func getPresignedUploadURL(filename: String, contentType: String) async throws -> (uploadURL: String, assetURL: String) {
        (uploadURL: "https://example.com/upload/\(filename)", assetURL: "https://example.com/asset/\(filename)")
    }

    func subscribeToTopics(deviceId: String, clientId: String, topics: [String]) async throws {}
    func unsubscribeFromTopics(clientId: String, topics: [String]) async throws {}
    func unregisterInstallation(clientId: String) async throws {}

    func renewAssetsBatch(assetKeys: [String]) async throws -> AssetRenewalResult {
        AssetRenewalResult(renewed: assetKeys.count, failed: 0, expiredKeys: [])
    }

    func requestAgentJoin(slug: String, instructions: String, forceErrorCode: Int?) async throws -> ConvosAPI.AgentJoinResponse {
        .init(success: true, joined: true)
    }

    func redeemInviteCode(_ code: String) async throws -> ConvosAPI.InviteCodeStatus {
        .init(code: code, name: nil, maxRedemptions: 0, redemptionCount: 0, remainingRedemptions: 0)
    }

    func fetchInviteCodeStatus(_ code: String) async throws -> ConvosAPI.InviteCodeStatus {
        .init(code: code, name: nil, maxRedemptions: 0, redemptionCount: 0, remainingRedemptions: 0)
    }

    func initiateCloudConnection(serviceId: String, redirectUri: String) async throws -> CloudConnectionsAPI.InitiateResponse {
        .init(connectionRequestId: "stub-request", redirectUrl: "https://example.com/oauth")
    }

    func completeCloudConnection(connectionRequestId: String) async throws -> CloudConnectionsAPI.CompleteResponse {
        .init(
            connectionId: "stub-conn",
            serviceId: "google_calendar",
            serviceName: "Google Calendar",
            composioEntityId: "entity",
            composioConnectionId: "ca",
            status: "ACTIVE"
        )
    }

    func listCloudConnections() async throws -> [CloudConnectionsAPI.ConnectionResponse] {
        stubbedConnections
    }

    func revokeCloudConnection(connectionId: String) async throws {
        revokedConnectionIds.append(connectionId)
    }

    enum StubError: Error {
        case invalidURL
    }
}

private actor RecordingGrantWriter: CloudConnectionGrantWriterProtocol {
    struct Call: Sendable, Equatable {
        let connectionId: String
        let conversationId: String
    }

    private var calls: [Call] = []
    private var shouldThrow: Bool = false

    func setShouldThrow(_ value: Bool) {
        shouldThrow = value
    }

    func revokedGrants() -> [Call] {
        calls
    }

    nonisolated func grantConnection(_ connectionId: String, to conversationId: String) async throws {}

    func revokeGrant(connectionId: String, from conversationId: String) async throws {
        calls.append(Call(connectionId: connectionId, conversationId: conversationId))
        if shouldThrow {
            throw StubError.republishFailed
        }
    }

    enum StubError: Error {
        case republishFailed
    }
}

private struct StubOAuthSessionProvider: OAuthSessionProvider {
    func authenticate(url: URL, callbackURLScheme: String) async throws -> URL {
        url
    }
}

private actor RecordingEventWriter: ConnectionEventWriterProtocol {
    struct Call: Sendable, Equatable {
        let providerId: String
        let capability: ConnectionCapability?
        let conversationId: String
    }

    private var grants: [Call] = []
    private var revocations: [Call] = []
    private var shouldThrow: Bool = false

    func setShouldThrow(_ value: Bool) {
        shouldThrow = value
    }

    func grantedEvents() -> [Call] { grants }
    func revokedEvents() -> [Call] { revocations }

    func sendGranted(providerId: String, capability: ConnectionCapability?, in conversationId: String) async throws {
        grants.append(Call(providerId: providerId, capability: capability, conversationId: conversationId))
        if shouldThrow { throw StubError.sendFailed }
    }

    func sendRevoked(providerId: String, capability: ConnectionCapability?, in conversationId: String) async throws {
        revocations.append(Call(providerId: providerId, capability: capability, conversationId: conversationId))
        if shouldThrow { throw StubError.sendFailed }
    }

    enum StubError: Error {
        case sendFailed
    }
}

private actor RecordingResolver: CapabilityResolver {
    private var removed: [ProviderID] = []
    private var shouldThrow: Bool = false

    func setShouldThrow(_ value: Bool) {
        shouldThrow = value
    }

    func removedProviders() -> [ProviderID] { removed }

    func availableProviders(for subject: CapabilitySubject) async -> [any CapabilityProvider] { [] }

    func resolution(
        subject: CapabilitySubject,
        capability: ConnectionCapability,
        conversationId: String
    ) async -> Set<ProviderID> { [] }

    func setResolution(
        _ providerIds: Set<ProviderID>,
        subject: CapabilitySubject,
        capability: ConnectionCapability,
        conversationId: String
    ) async throws {}

    func clearResolution(
        subject: CapabilitySubject,
        capability: ConnectionCapability,
        conversationId: String
    ) async throws {}

    func clearAllResolutions(
        subject: CapabilitySubject,
        conversationId: String
    ) async throws {}

    func removeProviderFromAllResolutions(_ providerId: ProviderID) async throws {
        removed.append(providerId)
        if shouldThrow { throw StubError.removeFailed }
    }

    enum StubError: Error {
        case removeFailed
    }
}
