@testable import ConvosCore
import Foundation
import Testing

/// Programmable stub over the abilities endpoints; everything else inherits
/// the throwing/no-op `TestStubAPIClient` surface. Closures are async so
/// concurrency tests can hold a request open to force overlap.
private final class AbilitiesStubAPIClient: TestStubAPIClient, @unchecked Sendable {
    var onGetAbilities: () async throws -> AbilitiesAPI.CatalogResponse = { throw APIError.invalidRequest }
    var onCreateEntitlement: (String, String?) async throws -> AbilitiesAPI.EntitlementInitiationResponse = { _, _ in throw APIError.invalidRequest }
    var onCompleteEntitlement: (String, String) async throws -> AbilitiesAPI.EntitlementCompleteResponse = { _, _ in throw APIError.invalidRequest }
    var onRevokeEntitlement: (String) async throws -> Void = { _ in }
    var onGetConversationAbilities: (String) async throws -> AbilitiesAPI.ConversationAbilitiesResponse = { _ in
        AbilitiesAPI.ConversationAbilitiesResponse(abilities: [])
    }
    var onPutConversationAbility: (String, String, String, [String], String?) async throws -> AbilitiesAPI.ConversationAbilityEntry = { _, _, _, _, _ in
        throw APIError.invalidRequest
    }
    var onDeleteConversationAbility: (String, String, String) async throws -> Void = { _, _, _ in }

    private(set) var createCalls: [String] = []
    private(set) var completeCalls: [(abilityId: String, connectionRequestId: String)] = []
    private(set) var putCalls: [(conversationId: String, abilityId: String, agentInboxId: String, bundleIds: [String], extendedByInboxId: String?)] = []

    override func getAbilities() async throws -> AbilitiesAPI.CatalogResponse {
        try await onGetAbilities()
    }

    override func createAbilityEntitlement(abilityId: String, redirectUri: String?) async throws -> AbilitiesAPI.EntitlementInitiationResponse {
        createCalls.append(abilityId)
        return try await onCreateEntitlement(abilityId, redirectUri)
    }

    @discardableResult
    override func completeAbilityEntitlement(abilityId: String, connectionRequestId: String) async throws -> AbilitiesAPI.EntitlementCompleteResponse {
        completeCalls.append((abilityId, connectionRequestId))
        return try await onCompleteEntitlement(abilityId, connectionRequestId)
    }

    override func revokeAbilityEntitlement(abilityId: String) async throws {
        try await onRevokeEntitlement(abilityId)
    }

    override func getConversationAbilities(conversationId: String) async throws -> AbilitiesAPI.ConversationAbilitiesResponse {
        try await onGetConversationAbilities(conversationId)
    }

    @discardableResult
    override func putConversationAbility(
        conversationId: String,
        abilityId: String,
        agentInboxId: String,
        bundleIds: [String],
        extendedByInboxId: String?
    ) async throws -> AbilitiesAPI.ConversationAbilityEntry {
        putCalls.append((conversationId, abilityId, agentInboxId, bundleIds, extendedByInboxId))
        return try await onPutConversationAbility(conversationId, abilityId, agentInboxId, bundleIds, extendedByInboxId)
    }

    override func deleteConversationAbility(conversationId: String, abilityId: String, agentInboxId: String) async throws {
        try await onDeleteConversationAbility(conversationId, abilityId, agentInboxId)
    }
}

@Suite("LiveAbilitiesService")
struct LiveAbilitiesServiceTests {
    private func makeService(
        client: AbilitiesStubAPIClient,
        cache: AbilitiesCatalogDiskCache? = nil,
        myInboxId: String? = "test-inbox"
    ) -> LiveAbilitiesService {
        LiveAbilitiesService(
            apiClient: client,
            callbackURLScheme: "convos-testing",
            cache: cache,
            myInboxIdProvider: myInboxId.map { (inboxId: String) -> @Sendable () async -> String? in
                { inboxId }
            }
        )
    }

    private func temporaryCache() -> AbilitiesCatalogDiskCache {
        AbilitiesCatalogDiskCache(
            directoryURL: FileManager.default.temporaryDirectory
                .appendingPathComponent("abilities-cache-tests-\(UUID().uuidString)", isDirectory: true),
            environmentName: "tests"
        )
    }

    private func authoritativeResponse() throws -> AbilitiesAPI.CatalogResponse {
        try AbilitiesAPI.CatalogResponse(
            catalogVersion: 7,
            abilities: MockAbilitiesService.standardCatalog()
        )
    }

    private func unavailableResponse() throws -> AbilitiesAPI.CatalogResponse {
        try AbilitiesAPI.CatalogResponse(
            catalogVersion: 7,
            entitlementsUnavailable: true,
            abilities: MockAbilitiesService.standardCatalog().map { $0.withEntitlementState(.unknown) }
        )
    }

    // MARK: - Catalog + persistence

    @Test("Authoritative fetch passes through and persists under the account scope")
    func authoritativeFetchPersists() async throws {
        let cache = temporaryCache()
        defer { cache.clearAll() }
        let client = AbilitiesStubAPIClient()
        client.onGetAbilities = { try self.authoritativeResponse() }
        let service = makeService(client: client, cache: cache)

        let catalog = try await service.fetchCatalog()
        #expect(!catalog.entitlementsUnavailable)
        #expect(catalog.abilities.contains { $0.id == "googlecalendar" && $0.entitlement?.status == .active })

        let reloaded = try #require(cache.load(scope: "test-inbox"))
        #expect(reloaded.catalogVersion == catalog.catalogVersion)
        #expect(reloaded.abilities.first { $0.id == "googlecalendar" }?.entitlement?.status == .active)
    }

    @Test("Outage fetch after restart resolves against the disk-cached last-known catalog")
    func outageFetchUsesDiskCacheAcrossRestart() async throws {
        let cache = temporaryCache()
        defer { cache.clearAll() }

        let firstClient = AbilitiesStubAPIClient()
        firstClient.onGetAbilities = { try self.authoritativeResponse() }
        let firstService = makeService(client: firstClient, cache: cache)
        _ = try await firstService.fetchCatalog()

        // A fresh service instance simulates a process restart: only the
        // disk cache carries state forward.
        let secondClient = AbilitiesStubAPIClient()
        secondClient.onGetAbilities = { try self.unavailableResponse() }
        let secondService = makeService(client: secondClient, cache: cache)

        let catalog = try await secondService.fetchCatalog()
        #expect(catalog.entitlementsUnavailable)
        #expect(catalog.abilities.first { $0.id == "googlecalendar" }?.entitlement?.status == .active)
        #expect(catalog.abilities.first { $0.id == "spotify" }?.entitlement?.status == .pendingAuth)
    }

    @Test("Another account's cache never carries into a different scope")
    func cacheIsScopedPerAccount() async throws {
        let cache = temporaryCache()
        defer { cache.clearAll() }

        let firstClient = AbilitiesStubAPIClient()
        firstClient.onGetAbilities = { try self.authoritativeResponse() }
        _ = try await makeService(client: firstClient, cache: cache, myInboxId: "inbox-a").fetchCatalog()

        let secondClient = AbilitiesStubAPIClient()
        secondClient.onGetAbilities = { try self.unavailableResponse() }
        let serviceB = makeService(client: secondClient, cache: cache, myInboxId: "inbox-b")

        let catalog = try await serviceB.fetchCatalog()
        #expect(catalog.entitlementsUnavailable)
        #expect(catalog.abilities.allSatisfy { $0.entitlementState == .unknown })
    }

    @Test("Device-only fetches (no resolvable scope) never touch the disk cache")
    func deviceOnlyNeverPersists() async throws {
        let cache = temporaryCache()
        defer { cache.clearAll() }

        // Seed an account-scoped cache, then fetch as an accountless caller.
        let accountClient = AbilitiesStubAPIClient()
        accountClient.onGetAbilities = { try self.authoritativeResponse() }
        _ = try await makeService(client: accountClient, cache: cache, myInboxId: "inbox-a").fetchCatalog()

        let deviceOnlyClient = AbilitiesStubAPIClient()
        deviceOnlyClient.onGetAbilities = {
            try AbilitiesAPI.CatalogResponse(
                catalogVersion: 7,
                abilities: MockAbilitiesService.standardCatalog().map { $0.withEntitlementState(.notEntitled) }
            )
        }
        let deviceOnlyProvider: @Sendable () async -> String? = { nil }
        let deviceOnlyService = LiveAbilitiesService(
            apiClient: deviceOnlyClient,
            callbackURLScheme: "convos-testing",
            cache: cache,
            myInboxIdProvider: deviceOnlyProvider
        )
        _ = try await deviceOnlyService.fetchCatalog()

        // The account's file is untouched by the accountless fetch.
        let reloaded = try #require(cache.load(scope: "inbox-a"))
        #expect(reloaded.abilities.first { $0.id == "googlecalendar" }?.entitlement?.status == .active)
    }

    @Test("Cold-start outage with no cache resolves every ability unknown")
    func outageColdStart() async throws {
        let client = AbilitiesStubAPIClient()
        client.onGetAbilities = { try self.unavailableResponse() }
        let service = makeService(client: client, cache: nil)

        let catalog = try await service.fetchCatalog()
        #expect(catalog.entitlementsUnavailable)
        #expect(catalog.abilities.allSatisfy { $0.entitlementState == .unknown })
    }

    // MARK: - Entitlement lifecycle

    @Test("Begin stores the attempt and complete echoes its id")
    func beginThenComplete() async throws {
        let client = AbilitiesStubAPIClient()
        client.onCreateEntitlement = { abilityId, redirectUri in
            #expect(redirectUri == "convos-testing://connections/callback")
            return AbilitiesAPI.EntitlementInitiationResponse(
                status: .pendingAuth,
                redirectUrl: "https://consent.example/\(abilityId)",
                connectionRequestId: "creq-42"
            )
        }
        client.onCompleteEntitlement = { _, _ in AbilitiesAPI.EntitlementCompleteResponse() }
        let service = makeService(client: client)

        let initiation = try await service.beginEntitlement(abilityId: "spotify")
        #expect(initiation.status == .pendingAuth)
        #expect(initiation.redirectUrl == "https://consent.example/spotify")

        try await service.completeEntitlement(abilityId: "spotify")
        #expect(client.completeCalls.map(\.connectionRequestId) == ["creq-42"])
    }

    @Test("Complete without a prior begin fails with missingConnectionRequest")
    func completeWithoutBegin() async throws {
        let service = makeService(client: AbilitiesStubAPIClient())
        await #expect(throws: LiveAbilitiesServiceError.missingConnectionRequest(abilityId: "spotify")) {
            try await service.completeEntitlement(abilityId: "spotify")
        }
    }

    @Test("Continue connecting resumes the retained attempt: no new begin, same id")
    func continueResumesRetainedAttempt() async throws {
        let client = AbilitiesStubAPIClient()
        client.onCreateEntitlement = { _, _ in
            AbilitiesAPI.EntitlementInitiationResponse(
                status: .pendingAuth,
                redirectUrl: "https://consent.example/x",
                connectionRequestId: "creq-7"
            )
        }
        client.onCompleteEntitlement = { _, _ in
            throw AbilitiesAPI.EndpointError.authIncomplete(connectionStatus: "INITIALIZING")
        }
        let service = makeService(client: client)
        _ = try await service.beginEntitlement(abilityId: "spotify")

        await #expect(throws: AbilitiesAPI.EndpointError.authIncomplete(connectionStatus: "INITIALIZING")) {
            try await service.completeEntitlement(abilityId: "spotify")
        }

        // The Continue path: connect re-runs begin, which must serve the
        // retained attempt instead of minting a new connection request.
        let resumed = try await service.beginEntitlement(abilityId: "spotify")
        #expect(resumed.status == .pendingAuth)
        #expect(resumed.redirectUrl == "https://consent.example/x")
        #expect(client.createCalls.count == 1)

        client.onCompleteEntitlement = { _, _ in AbilitiesAPI.EntitlementCompleteResponse() }
        try await service.completeEntitlement(abilityId: "spotify")
        #expect(client.completeCalls.map(\.connectionRequestId) == ["creq-7", "creq-7"])
    }

    @Test("A non-authIncomplete completion failure drops the attempt so the next connect re-begins")
    func otherCompleteFailureDropsAttempt() async throws {
        let client = AbilitiesStubAPIClient()
        client.onCreateEntitlement = { _, _ in
            AbilitiesAPI.EntitlementInitiationResponse(
                status: .pendingAuth,
                redirectUrl: "https://consent.example/x",
                connectionRequestId: "creq-1"
            )
        }
        client.onCompleteEntitlement = { _, _ in
            throw AbilitiesAPI.EndpointError.abilityMismatch
        }
        let service = makeService(client: client)
        _ = try await service.beginEntitlement(abilityId: "spotify")

        await #expect(throws: AbilitiesAPI.EndpointError.abilityMismatch) {
            try await service.completeEntitlement(abilityId: "spotify")
        }

        _ = try await service.beginEntitlement(abilityId: "spotify")
        #expect(client.createCalls.count == 2)
    }

    @Test("Overlapping begins share one backend connection request")
    func concurrentBeginsShareOneRequest() async throws {
        let client = AbilitiesStubAPIClient()
        client.onCreateEntitlement = { _, _ in
            try await Task.sleep(for: .milliseconds(50))
            return AbilitiesAPI.EntitlementInitiationResponse(
                status: .pendingAuth,
                redirectUrl: "https://consent.example/x",
                connectionRequestId: "creq-shared"
            )
        }
        let service = makeService(client: client)

        async let first = service.beginEntitlement(abilityId: "spotify")
        async let second = service.beginEntitlement(abilityId: "spotify")
        let results = try await [first, second]

        #expect(client.createCalls.count == 1)
        #expect(results.allSatisfy { $0.redirectUrl == "https://consent.example/x" })
    }

    @Test("Duplicate completes submit the connection-request id exactly once")
    func concurrentCompletesSubmitOnce() async throws {
        let client = AbilitiesStubAPIClient()
        client.onCreateEntitlement = { _, _ in
            AbilitiesAPI.EntitlementInitiationResponse(
                status: .pendingAuth,
                redirectUrl: "https://consent.example/x",
                connectionRequestId: "creq-9"
            )
        }
        client.onCompleteEntitlement = { _, _ in
            try await Task.sleep(for: .milliseconds(50))
            return AbilitiesAPI.EntitlementCompleteResponse()
        }
        let service = makeService(client: client)
        _ = try await service.beginEntitlement(abilityId: "spotify")

        async let first: Void = service.completeEntitlement(abilityId: "spotify")
        async let second: Void = service.completeEntitlement(abilityId: "spotify")
        _ = try await [first, second]

        #expect(client.completeCalls.count == 1)
    }

    @Test("requireAccount rejections surface as accountRequired")
    func forbiddenMapsToAccountRequired() async throws {
        let client = AbilitiesStubAPIClient()
        client.onCreateEntitlement = { _, _ in throw APIError.forbidden }
        let service = makeService(client: client)
        await #expect(throws: AbilitiesServiceError.accountRequired) {
            _ = try await service.beginEntitlement(abilityId: "spotify")
        }
    }

    @Test("unknown_ability maps to the service-level unknownAbility")
    func unknownAbilityMaps() async throws {
        let client = AbilitiesStubAPIClient()
        client.onCreateEntitlement = { _, _ in throw AbilitiesAPI.EndpointError.unknownAbility }
        let service = makeService(client: client)
        await #expect(throws: AbilitiesServiceError.unknownAbility(abilityId: "ghost")) {
            _ = try await service.beginEntitlement(abilityId: "ghost")
        }
    }

    // MARK: - Conversation extensions

    @Test("Conversation opt-ins keep only the caller's own entries")
    func conversationAbilitiesFiltersExtendedByMe() async throws {
        let client = AbilitiesStubAPIClient()
        client.onGetConversationAbilities = { conversationId in
            AbilitiesAPI.ConversationAbilitiesResponse(abilities: [
                AbilitiesAPI.ConversationAbilityEntry(
                    abilityId: "googlecalendar",
                    conversationId: conversationId,
                    agentInboxId: "agent-1",
                    bundleIds: ["calendar.events"],
                    extendedByInboxId: "me",
                    extendedByMe: true,
                    status: .active,
                    createdAt: Date(),
                    updatedAt: Date()
                ),
                AbilitiesAPI.ConversationAbilityEntry(
                    abilityId: "spotify",
                    conversationId: conversationId,
                    agentInboxId: "agent-1",
                    bundleIds: [],
                    extendedByInboxId: nil,
                    extendedByMe: false,
                    status: .active,
                    createdAt: Date(),
                    updatedAt: Date()
                ),
            ])
        }
        let service = makeService(client: client)

        let optIns = try await service.conversationAbilities(conversationId: "conv-1")
        #expect(optIns.map(\.abilityId) == ["googlecalendar"])
        #expect(optIns.first?.bundleIds == ["calendar.events"])
    }

    @Test("Extend sends the caller's inbox id and maps needs_entitlement")
    func extendMapsNeedsEntitlement() async throws {
        let client = AbilitiesStubAPIClient()
        client.onPutConversationAbility = { _, _, _, _, _ in
            throw AbilitiesAPI.EndpointError.needsEntitlement
        }
        let service = makeService(client: client, myInboxId: "my-inbox")

        await #expect(throws: AbilitiesServiceError.needsEntitlement(abilityId: "googlecalendar")) {
            try await service.extendAbility(
                conversationId: "conv-1",
                abilityId: "googlecalendar",
                agentInboxId: "agent-1",
                bundleIds: ["calendar.events"]
            )
        }
        #expect(client.putCalls.first?.extendedByInboxId == "my-inbox")
    }

    @Test("Extend passes the retryable entitlements_unavailable through typed")
    func extendPassesEntitlementsUnavailable() async throws {
        let client = AbilitiesStubAPIClient()
        client.onPutConversationAbility = { _, _, _, _, _ in
            throw AbilitiesAPI.EndpointError.entitlementsUnavailable
        }
        let service = makeService(client: client)
        await #expect(throws: AbilitiesAPI.EndpointError.entitlementsUnavailable) {
            try await service.extendAbility(
                conversationId: "conv-1",
                abilityId: "googlecalendar",
                agentInboxId: "agent-1",
                bundleIds: ["calendar.events"]
            )
        }
    }

    @Test("A zero-bundle extension is rejected client-side without a round-trip")
    func zeroBundleExtendRejected() async throws {
        let client = AbilitiesStubAPIClient()
        let service = makeService(client: client)
        await #expect(throws: LiveAbilitiesServiceError.noBundlesSelected(abilityId: "googlecalendar")) {
            try await service.extendAbility(
                conversationId: "conv-1",
                abilityId: "googlecalendar",
                agentInboxId: "agent-1",
                bundleIds: []
            )
        }
        #expect(client.putCalls.isEmpty)
    }

    @Test("Withdraw treats a not_found as already done")
    func withdrawNotFoundIsBenign() async throws {
        let client = AbilitiesStubAPIClient()
        client.onDeleteConversationAbility = { _, _, _ in throw APIError.notFound }
        let service = makeService(client: client)
        try await service.withdrawAbility(conversationId: "conv-1", abilityId: "googlecalendar", agentInboxId: "agent-1")
    }
}

@Suite("AbilitiesCatalogDiskCache")
struct AbilitiesCatalogDiskCacheTests {
    private func temporaryCache() -> AbilitiesCatalogDiskCache {
        AbilitiesCatalogDiskCache(
            directoryURL: FileManager.default.temporaryDirectory
                .appendingPathComponent("abilities-cache-tests-\(UUID().uuidString)", isDirectory: true),
            environmentName: "tests"
        )
    }

    @Test("Corrupt cache files read as no cache and are cleared")
    func corruptFileClears() throws {
        let cache = temporaryCache()
        defer { cache.clearAll() }
        let fileURL = cache.fileURL(scope: "inbox-a")
        try FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data("not json".utf8).write(to: fileURL)
        #expect(cache.load(scope: "inbox-a") == nil)
        #expect(!FileManager.default.fileExists(atPath: fileURL.path))
    }

    @Test("Round-trips the entitlement three-state per scope")
    func roundTripsThreeState() throws {
        let cache = temporaryCache()
        defer { cache.clearAll() }

        let entitled = MockAbilitiesService.standardCatalog()
        var abilities = entitled
        if let last = abilities.popLast() {
            abilities.append(last.withEntitlementState(.unknown))
        }
        let catalog = AbilitiesCatalog(catalogVersion: 9, entitlementsUnavailable: true, abilities: abilities)
        cache.save(catalog, scope: "inbox-a")

        let reloaded = try #require(cache.load(scope: "inbox-a"))
        #expect(reloaded.catalogVersion == 9)
        #expect(reloaded.entitlementsUnavailable)
        #expect(reloaded.abilities.last?.entitlementState == .unknown)
        #expect(reloaded.abilities.first?.entitlement?.status == .active)

        // A different scope reads nothing, and clearAll drops every scope.
        #expect(cache.load(scope: "inbox-b") == nil)
        cache.clearAll()
        #expect(cache.load(scope: "inbox-a") == nil)
    }
}
