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

/// Mutable identity for tests that switch accounts mid-run. Reads and
/// writes are sequenced by the test body itself.
/// A one-shot gate a stubbed endpoint can park on, so a test can hold one
/// request open while it drives another.
private actor TestGate {
    private var isOpen: Bool = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        guard !isOpen else { return }
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            waiters.append(continuation)
        }
    }

    func open() {
        isOpen = true
        let resumed = waiters
        waiters = []
        for continuation in resumed {
            continuation.resume()
        }
    }
}

private final class ScopeBox: @unchecked Sendable {
    var inboxId: String?

    init(inboxId: String?) {
        self.inboxId = inboxId
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
            return try AbilitiesAPI.EntitlementInitiationResponse(
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

    /// The reported dead end: an OAuth the member walked away from leaves a
    /// `pendingAuth` entitlement whose consent URL expires on the provider's
    /// clock. Re-serving that URL on the next connect tap lands them on
    /// "link session has expired" with nothing to do about it, so a restart
    /// always mints a new link session.
    ///
    /// Here the retained round is genuinely dead (completion is rejected
    /// outright), which is the branch that has to fall through to a mint.
    @Test("A later connect tap on a dead round mints a fresh link session")
    func laterConnectMintsAFreshSession() async throws {
        let client = AbilitiesStubAPIClient()
        client.onCreateEntitlement = { _, _ in
            try AbilitiesAPI.EntitlementInitiationResponse(
                status: .pendingAuth,
                redirectUrl: "https://consent.example/stale",
                connectionRequestId: "creq-stale"
            )
        }
        client.onCompleteEntitlement = { _, _ in throw AbilitiesAPI.EndpointError.abilityMismatch }
        let service = makeService(client: client)

        let first = try await service.beginEntitlement(abilityId: "spotify")
        #expect(first.redirectUrl == "https://consent.example/stale")

        // The member abandoned that round; by the time they tap again the
        // link session behind it is dead, and so is the request.
        client.onCreateEntitlement = { _, _ in
            try AbilitiesAPI.EntitlementInitiationResponse(
                status: .pendingAuth,
                redirectUrl: "https://consent.example/fresh",
                connectionRequestId: "creq-fresh"
            )
        }
        let second = try await service.beginEntitlement(abilityId: "spotify")

        #expect(second.status == .pendingAuth)
        #expect(second.redirectUrl == "https://consent.example/fresh", "a stored URL must never be replayed")
        #expect(client.createCalls.count == 2, "the tap has to reach initiate to get a live session")

        client.onCompleteEntitlement = { _, _ in AbilitiesAPI.EntitlementCompleteResponse() }
        try await service.completeEntitlement(abilityId: "spotify")
        #expect(client.completeCalls.map(\.connectionRequestId).last == "creq-fresh", "completion echoes the round it belongs to")
    }

    /// The other branch, and the one the bug report never got to see: the
    /// member did finish consent, the completion retries ran out while
    /// Composio was still INITIALIZING, and the connection went ACTIVE
    /// afterwards. No webhook exists, so the entitlement row is still
    /// `pending_auth` and only a complete this client sends can move it.
    /// The next tap must therefore re-submit the retained id before minting
    /// anything -- otherwise the member signs in a second time for a
    /// connection that already works.
    @Test("A later connect tap finishes the outstanding round instead of re-authorizing")
    func laterConnectFinishesTheOutstandingRound() async throws {
        let client = AbilitiesStubAPIClient()
        client.onCreateEntitlement = { _, _ in
            try AbilitiesAPI.EntitlementInitiationResponse(
                status: .pendingAuth,
                redirectUrl: "https://consent.example/x",
                connectionRequestId: "creq-slow"
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

        // Composio finishes; nothing tells the backend.
        client.onCompleteEntitlement = { _, _ in AbilitiesAPI.EntitlementCompleteResponse() }
        let resumed = try await service.beginEntitlement(abilityId: "spotify")

        #expect(resumed.status == .active, "the round completed, so there is nothing to authorize")
        #expect(resumed.redirectUrl == nil)
        #expect(client.createCalls.count == 1, "no new link session is minted for a round that just finished")
        #expect(client.completeCalls.map(\.connectionRequestId) == ["creq-slow", "creq-slow"])
    }

    /// `auth_incomplete` keeps the id: the bounded completion retry
    /// re-submits it inside the round, and a later connect tap re-submits it
    /// once more before falling through to a fresh session.
    @Test("authIncomplete retries the same id, then the next tap re-tries it before minting")
    func authIncompleteRetriesTheSameIdThenStartsOver() async throws {
        let client = AbilitiesStubAPIClient()
        client.onCreateEntitlement = { _, _ in
            try AbilitiesAPI.EntitlementInitiationResponse(
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

        for _ in 0..<2 {
            await #expect(throws: AbilitiesAPI.EndpointError.authIncomplete(connectionStatus: "INITIALIZING")) {
                try await service.completeEntitlement(abilityId: "spotify")
            }
        }
        #expect(client.completeCalls.map(\.connectionRequestId) == ["creq-7", "creq-7"], "same round, same id")
        #expect(client.createCalls.count == 1, "retrying completion never re-initiates")

        client.onCreateEntitlement = { _, _ in
            try AbilitiesAPI.EntitlementInitiationResponse(
                status: .pendingAuth,
                redirectUrl: "https://consent.example/y",
                connectionRequestId: "creq-8"
            )
        }
        let restarted = try await service.beginEntitlement(abilityId: "spotify")
        #expect(restarted.redirectUrl == "https://consent.example/y")
        #expect(client.createCalls.count == 2)
        #expect(client.completeCalls.count == 3, "the tap tried the outstanding round once more first")
    }

    /// The backend links unconditionally before consulting the entitlement
    /// row, so an OAuth ability whose row is already active answers `active`
    /// while still carrying the auth fields of the request it just minted.
    /// Rejecting that shape makes the client throw on a connection that
    /// genuinely works; both shapes have to decode, and neither leaves the
    /// caller anything to authorize.
    @Test("Both shapes of an active initiation decode and carry no authorization step")
    func activeInitiationDecodesInBothShapes() async throws {
        let authLess = #"{"status":"active","redirectUrl":null,"connectionRequestId":null}"#
        let oauth = #"{"status":"active","redirectUrl":"https://consent.example/unused","connectionRequestId":"creq-unused"}"#

        for wire in [authLess, oauth] {
            let decoded = try JSONDecoder().decode(AbilitiesAPI.EntitlementInitiationResponse.self, from: Data(wire.utf8))
            #expect(decoded.status == .active)

            let client = AbilitiesStubAPIClient()
            client.onCreateEntitlement = { _, _ in decoded }
            let service = makeService(client: client)

            let initiation = try await service.beginEntitlement(abilityId: "spotify")
            #expect(initiation.status == .active)
            #expect(initiation.redirectUrl == nil, "an active entitlement has nothing to authorize")

            // The minted-but-unused request is not a round to complete later.
            await #expect(throws: LiveAbilitiesServiceError.missingConnectionRequest(abilityId: "spotify")) {
                try await service.completeEntitlement(abilityId: "spotify")
            }
        }
    }

    /// A completion can outlive the surface that started it -- the composer
    /// modal's connect deliberately survives dismissal -- so a connect tap
    /// elsewhere can land while one is still in flight. It must not open a
    /// competing round against the same ability: it joins the completion
    /// already running, and only mints if that one did not finish the job.
    /// This is what keeps a concluding round from ever concluding *over* a
    /// newer one's retained id.
    @Test("A connect tap during an in-flight completion joins it instead of racing it")
    func connectDuringCompletionJoinsIt() async throws {
        let client = AbilitiesStubAPIClient()
        client.onCreateEntitlement = { _, _ in
            try AbilitiesAPI.EntitlementInitiationResponse(
                status: .pendingAuth,
                redirectUrl: "https://consent.example/first",
                connectionRequestId: "creq-first"
            )
        }
        let completionGate = TestGate()
        client.onCompleteEntitlement = { _, _ in
            await completionGate.wait()
            return AbilitiesAPI.EntitlementCompleteResponse()
        }
        let service = makeService(client: client)
        _ = try await service.beginEntitlement(abilityId: "spotify")

        let completion = Task { try await service.completeEntitlement(abilityId: "spotify") }
        try await Task.sleep(for: .milliseconds(50))

        let tap = Task { try await service.beginEntitlement(abilityId: "spotify") }
        try await Task.sleep(for: .milliseconds(50))
        #expect(client.createCalls.count == 1, "the tap must not mint while the round is still resolving")

        await completionGate.open()
        try await completion.value
        let resumed = try await tap.value

        #expect(resumed.status == .active, "the round it joined finished it")
        #expect(client.createCalls.count == 1)
        #expect(client.completeCalls.map(\.connectionRequestId) == ["creq-first"], "one round, submitted once")
    }

    @Test("Overlapping begins share one backend connection request")
    func concurrentBeginsShareOneRequest() async throws {
        let client = AbilitiesStubAPIClient()
        client.onCreateEntitlement = { _, _ in
            try await Task.sleep(for: .milliseconds(50))
            return try AbilitiesAPI.EntitlementInitiationResponse(
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
            try AbilitiesAPI.EntitlementInitiationResponse(
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

    @Test("An account switch drops the previous account's OAuth attempt")
    func accountSwitchDropsAttempt() async throws {
        let client = AbilitiesStubAPIClient()
        client.onCreateEntitlement = { _, _ in
            try AbilitiesAPI.EntitlementInitiationResponse(
                status: .pendingAuth,
                redirectUrl: "https://consent.example/a",
                connectionRequestId: "creq-account-a"
            )
        }
        let scopeBox = ScopeBox(inboxId: "inbox-a")
        let service = LiveAbilitiesService(
            apiClient: client,
            callbackURLScheme: "convos-testing",
            cache: nil,
            myInboxIdProvider: { scopeBox.inboxId }
        )

        _ = try await service.beginEntitlement(abilityId: "spotify")
        scopeBox.inboxId = "inbox-b"

        // The next begin under the new identity must detect the switch and
        // mint a fresh connection request instead of resuming inbox-a's.
        client.onCreateEntitlement = { _, _ in
            try AbilitiesAPI.EntitlementInitiationResponse(
                status: .pendingAuth,
                redirectUrl: "https://consent.example/b",
                connectionRequestId: "creq-account-b"
            )
        }
        let resumed = try await service.beginEntitlement(abilityId: "spotify")
        #expect(resumed.redirectUrl == "https://consent.example/b")
        #expect(client.createCalls.count == 2)

        // Completion echoes the new account's attempt, never inbox-a's.
        client.onCompleteEntitlement = { _, _ in AbilitiesAPI.EntitlementCompleteResponse() }
        try await service.completeEntitlement(abilityId: "spotify")
        #expect(client.completeCalls.map(\.connectionRequestId) == ["creq-account-b"])
    }

    @Test("A wipe during identity resolution fences out the late begin and fetch results")
    func wipeDuringIdentityResolutionFencesLateResults() async throws {
        let client = AbilitiesStubAPIClient()
        client.onGetAbilities = { try self.authoritativeResponse() }
        client.onCreateEntitlement = { _, _ in
            try AbilitiesAPI.EntitlementInitiationResponse(
                status: .pendingAuth,
                redirectUrl: "https://consent.example/x",
                connectionRequestId: "creq-pre-wipe"
            )
        }
        let cache = temporaryCache()
        let service = LiveAbilitiesService(
            apiClient: client,
            callbackURLScheme: "convos-testing",
            cache: cache,
            myInboxIdProvider: {
                try? await Task.sleep(for: .milliseconds(150))
                return "test-inbox"
            }
        )

        // Both operations enter, then suspend in the identity provider;
        // the wipe lands mid-resolution, after their entry marks.
        async let fetch = service.fetchCatalog()
        async let begin = service.beginEntitlement(abilityId: "spotify")
        try await Task.sleep(for: .milliseconds(50))
        await service.handleAccountDataWiped()
        _ = try await fetch
        _ = try await begin

        // The late fetch must not recreate the wiped cache file, and the
        // late begin must not retain the pre-wipe OAuth attempt: a
        // complete after the wipe finds no connection request.
        #expect(cache.load(scope: "test-inbox") == nil)
        await #expect(throws: LiveAbilitiesServiceError.missingConnectionRequest(abilityId: "spotify")) {
            try await service.completeEntitlement(abilityId: "spotify")
        }
    }

    @Test("A late-finishing older fetch cannot clobber newer committed state")
    func lateOlderFetchDoesNotClobber() async throws {
        let client = AbilitiesStubAPIClient()
        let staleAbilities: [AbilitiesAPI.Ability] = MockAbilitiesService.standardCatalog()
            .map { $0.withEntitlementState(.notEntitled) }
        client.onGetAbilities = {
            try await Task.sleep(for: .milliseconds(200))
            return try AbilitiesAPI.CatalogResponse(catalogVersion: 6, abilities: staleAbilities)
        }
        let service = makeService(client: client)

        async let older = service.fetchCatalog()
        try await Task.sleep(for: .milliseconds(50))
        client.onGetAbilities = { try self.authoritativeResponse() }
        _ = try await service.fetchCatalog()
        _ = try await older

        // Outage resolution must carry the newer fetch's committed state:
        // googlecalendar stays active instead of reverting to the stale
        // snapshot the older fetch delivered late.
        client.onGetAbilities = { try self.unavailableResponse() }
        let resolved = try await service.fetchCatalog()
        #expect(resolved.abilities.first { $0.id == "googlecalendar" }?.entitlement?.status == .active)
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
