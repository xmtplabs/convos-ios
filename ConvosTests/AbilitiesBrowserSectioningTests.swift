@testable import Convos
import ConvosCore
import XCTest

/// The Connections browser's two-section split in `.composerModal`:
/// Connected holds the entitlements whose authorization actually finished,
/// Discover holds everything still connectable - not-entitled, the
/// `pendingAuth` records an abandoned OAuth leaves behind, and `revoked`
/// ones a member severed - and the outage section holds the rest.
@MainActor
final class AbilitiesBrowserSectioningTests: XCTestCase {
    func testRepairableEntitlementsStayUnderConnected() async throws {
        let viewModel = AbilitiesListViewModel(service: MockAbilitiesService(scenario: .standard, artificialDelay: .zero))
        await viewModel.refresh()

        // The standard fixture: an active Google Calendar, a pendingAuth
        // Spotify and an expired Coinbase, all entitled.
        let connectedIds: [String] = viewModel.entitledAbilities.map(\.id)
        XCTAssertTrue(connectedIds.contains("googlecalendar"))
        XCTAssertTrue(connectedIds.contains("coinbase"), "expired is a connection that existed and can be repaired")

        let discoverIds: [String] = viewModel.availableAbilities.map(\.id)
        XCTAssertFalse(discoverIds.contains("coinbase"))
        XCTAssertTrue(discoverIds.contains("youtube"))
    }

    /// The reported dead end: an OAuth the member started and abandoned
    /// leaves a `pendingAuth` entitlement, which used to advertise itself
    /// under Connected with a Pending chip and a repair route that could
    /// only re-offer the dead consent link. No account was ever linked, so
    /// the row belongs in Discover behind a plain Connect.
    func testPendingAuthThatNeverCompletedIsDiscoverableNotConnected() async throws {
        let viewModel = AbilitiesListViewModel(service: MockAbilitiesService(scenario: .standard, artificialDelay: .zero))
        await viewModel.refresh()

        let spotify = try XCTUnwrap(MockAbilitiesService.standardCatalog().first { $0.id == "spotify" })
        XCTAssertEqual(spotify.entitlement?.status, .pendingAuth, "fixture guard: the test is about this status")

        XCTAssertFalse(viewModel.entitledAbilities.map(\.id).contains("spotify"))
        XCTAssertTrue(viewModel.availableAbilities.map(\.id).contains("spotify"))
    }

    /// Membership is a total function of entitlement state, so every status
    /// the wire contract can carry is pinned here rather than inferred from
    /// whichever ones the mock fixture happens to produce.
    func testEverySectionMappingIsPinned() throws {
        let template = try XCTUnwrap(MockAbilitiesService.standardCatalog().first { $0.id == "gmail" })

        let expected: [(AbilitiesAPI.EntitlementStatus, AbilitiesListViewModel.BrowserSection)] = [
            (.active, .connected),
            (.expired, .connected),
            (.needsReauth, .connected),
            (.revoked, .discover),
            (.pendingAuth, .discover),
        ]
        for (status, section) in expected {
            let entitlement = try AbilitiesAPI.Entitlement(status: status, expiresAt: nil, extensionCount: 0)
            let ability = template.withEntitlementState(.entitled(entitlement))
            XCTAssertEqual(AbilitiesListViewModel.section(for: ability), section, "status \(status.rawValue)")
        }

        XCTAssertEqual(AbilitiesListViewModel.section(for: template.withEntitlementState(.notEntitled)), .discover)
        XCTAssertEqual(AbilitiesListViewModel.section(for: template.withEntitlementState(.unknown)), .statusUnknown)
    }

    func testNeedsReauthAbilityIsConnectedNotDiscoverable() async throws {
        let service = NeedsReauthAbilitiesService()
        let viewModel = AbilitiesListViewModel(service: service)
        await viewModel.refresh()

        XCTAssertEqual(viewModel.entitledAbilities.map(\.id), ["gmail"])
        XCTAssertTrue(viewModel.availableAbilities.isEmpty)
        XCTAssertTrue(viewModel.unknownStateAbilities.isEmpty)
    }

    /// Fail-open is the direction the catalog type exists to prevent: an
    /// ability whose entitlement state the backend could not report must
    /// not read as connectable, and must not read as connected either.
    func testUnknownStateAbilitiesAreInNeitherSection() async throws {
        let viewModel = AbilitiesListViewModel(
            service: MockAbilitiesService(scenario: .entitlementsUnavailableColdStart, artificialDelay: .zero)
        )
        await viewModel.refresh()

        XCTAssertTrue(viewModel.entitlementsUnavailable)
        XCTAssertTrue(viewModel.entitledAbilities.isEmpty)
        XCTAssertTrue(viewModel.availableAbilities.isEmpty)
        XCTAssertFalse(viewModel.unknownStateAbilities.isEmpty)
    }

    /// One search field, both sections: the filter narrows every section
    /// from one query, and a section filtered to empty hides itself.
    func testSearchNarrowsBothSectionsFromOneQuery() async throws {
        let viewModel = AbilitiesListViewModel(service: MockAbilitiesService(scenario: .standard, artificialDelay: .zero))
        await viewModel.refresh()

        viewModel.searchText = "youtube"
        XCTAssertEqual(viewModel.availableAbilities.map(\.id), ["youtube"])
        XCTAssertTrue(viewModel.entitledAbilities.isEmpty, "a section filtered to nothing hides its header")
        XCTAssertTrue(viewModel.hasVisibleAbilities)

        viewModel.searchText = "calend"
        XCTAssertEqual(viewModel.entitledAbilities.map(\.id), ["googlecalendar"])
        XCTAssertTrue(viewModel.availableAbilities.isEmpty)

        viewModel.searchText = "zzzz"
        XCTAssertFalse(viewModel.hasVisibleAbilities, "a no-match query hands the list to the search empty state")
        XCTAssertTrue(viewModel.isSearching)
    }

    /// The second half of the dead end: the Connect the member reaches on
    /// that Discover row has to open a live provider session. Each tap runs
    /// its own initiate and authorizes with the URL that call returned, so
    /// a tap made long after the abandoned round never re-opens the link
    /// session that went with it.
    func testEachConnectTapAuthorizesWithTheUrlItsOwnInitiateReturned() async throws {
        let service = StaleLinkAbilitiesService()
        let authorizer = RecordingAuthorizer()
        let viewModel = AbilitiesListViewModel(service: service, authorizer: authorizer)
        await viewModel.refresh()

        let spotify = try XCTUnwrap(viewModel.availableAbilities.first { $0.id == "spotify" })

        viewModel.connect(spotify)
        try await settle { await authorizer.urls.count == 1 }
        try await settle { !viewModel.isBusy(spotify) }

        // Much later: the first consent link is dead, and the member taps
        // the same row again.
        viewModel.connect(spotify)
        try await settle { await authorizer.urls.count == 2 }

        let observedUrls = await authorizer.urls
        XCTAssertEqual(observedUrls, ["https://consent.example/session-1", "https://consent.example/session-2"])
        let observedBegins = await service.beginCount
        XCTAssertEqual(observedBegins, 2, "a connect tap always reaches initiate for a live session")
    }

    /// Everything-connected collapses Discover on its own; nothing-connected
    /// puts the hero above a full Discover. Both already shipped - pinned
    /// here so the two-section split cannot quietly regress them.
    func testEmptyStatesNeedNoSectionOfTheirOwn() async throws {
        let allConnected = AbilitiesListViewModel(service: EverythingConnectedAbilitiesService())
        await allConnected.refresh()
        XCTAssertFalse(allConnected.entitledAbilities.isEmpty)
        XCTAssertTrue(allConnected.availableAbilities.isEmpty, "Discover self-collapses")
        XCTAssertFalse(allConnected.showsNothingConnectedHero)

        let nothingConnected = AbilitiesListViewModel(service: MockAbilitiesService(scenario: .deviceOnly, artificialDelay: .zero))
        await nothingConnected.refresh()
        XCTAssertTrue(nothingConnected.entitledAbilities.isEmpty)
        XCTAssertFalse(nothingConnected.availableAbilities.isEmpty)
        XCTAssertTrue(nothingConnected.showsNothingConnectedHero)
    }

    /// Polls a condition inside the test's own turn: the connect flow runs
    /// on detached tasks, so there is nothing to await directly.
    private func settle(
        timeout: Duration = .seconds(2),
        until condition: () async -> Bool
    ) async throws {
        let deadline = ContinuousClock.now.advanced(by: timeout)
        while ContinuousClock.now < deadline {
            if await condition() { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTFail("condition never settled within \(timeout)")
    }
}

/// A single ability whose entitlement the provider says needs
/// reauthorization - the state `MockAbilitiesService` never produces.
private struct NeedsReauthAbilitiesService: AbilitiesServiceProtocol {
    func fetchCatalog() async throws -> AbilitiesCatalog {
        let gmail = try XCTUnwrap(MockAbilitiesService.standardCatalog().first { $0.id == "gmail" })
        let entitlement = try AbilitiesAPI.Entitlement(status: .needsReauth, expiresAt: nil, extensionCount: 1)
        return AbilitiesCatalog(catalogVersion: 1, abilities: [gmail.withEntitlementState(.entitled(entitlement))])
    }

    func beginEntitlement(abilityId: String) async throws -> AbilityEntitlementInitiation {
        throw AbilitiesServiceError.accountRequired
    }

    func completeEntitlement(abilityId: String) async throws {
        throw AbilitiesServiceError.accountRequired
    }

    func revokeEntitlement(abilityId: String) async throws {
        throw AbilitiesServiceError.accountRequired
    }

    func conversationAbilities(conversationId: String) async throws -> [ConversationAbility] {
        []
    }

    func extendAbility(conversationId: String, abilityId: String, agentInboxId: String, bundleIds: [String]) async throws {
        throw AbilitiesServiceError.accountRequired
    }

    func withdrawAbility(conversationId: String, abilityId: String, agentInboxId: String) async throws {
        throw AbilitiesServiceError.accountRequired
    }
}

/// Every catalog ability entitled and active: the "everything connected"
/// empty state, which no `MockAbilitiesService` scenario produces.
private struct EverythingConnectedAbilitiesService: AbilitiesServiceProtocol {
    func fetchCatalog() async throws -> AbilitiesCatalog {
        let entitlement = try AbilitiesAPI.Entitlement(status: .active, expiresAt: nil, extensionCount: 0)
        let abilities: [AbilitiesAPI.Ability] = MockAbilitiesService.standardCatalog()
            .map { $0.withEntitlementState(.entitled(entitlement)) }
        return AbilitiesCatalog(catalogVersion: 1, abilities: abilities)
    }

    func beginEntitlement(abilityId: String) async throws -> AbilityEntitlementInitiation {
        throw AbilitiesServiceError.accountRequired
    }

    func completeEntitlement(abilityId: String) async throws {
        throw AbilitiesServiceError.accountRequired
    }

    func revokeEntitlement(abilityId: String) async throws {
        throw AbilitiesServiceError.accountRequired
    }

    func conversationAbilities(conversationId: String) async throws -> [ConversationAbility] {
        []
    }

    func extendAbility(conversationId: String, abilityId: String, agentInboxId: String, bundleIds: [String]) async throws {
        throw AbilitiesServiceError.accountRequired
    }

    func withdrawAbility(conversationId: String, abilityId: String, agentInboxId: String) async throws {
        throw AbilitiesServiceError.accountRequired
    }
}

/// One `pendingAuth` Spotify the member never finished authorizing, and an
/// initiate that hands out a different link session on every call - the
/// shape a real provider has, and the one a replayed URL would flatten.
private actor StaleLinkAbilitiesService: AbilitiesServiceProtocol {
    private(set) var beginCount: Int = 0

    func fetchCatalog() async throws -> AbilitiesCatalog {
        let spotify = MockAbilitiesService.standardCatalog().first { $0.id == "spotify" }
        guard let spotify else { throw AbilitiesServiceError.unknownAbility(abilityId: "spotify") }
        let entitlement = try AbilitiesAPI.Entitlement(status: .pendingAuth, expiresAt: nil, extensionCount: 0)
        return AbilitiesCatalog(catalogVersion: 1, abilities: [spotify.withEntitlementState(.entitled(entitlement))])
    }

    func beginEntitlement(abilityId: String) async throws -> AbilityEntitlementInitiation {
        beginCount += 1
        return AbilityEntitlementInitiation(status: .pendingAuth, redirectUrl: "https://consent.example/session-\(beginCount)")
    }

    func completeEntitlement(abilityId: String) async throws {}

    func revokeEntitlement(abilityId: String) async throws {}

    func conversationAbilities(conversationId: String) async throws -> [ConversationAbility] {
        []
    }

    func extendAbility(conversationId: String, abilityId: String, agentInboxId: String, bundleIds: [String]) async throws {}

    func withdrawAbility(conversationId: String, abilityId: String, agentInboxId: String) async throws {}
}

/// Records what the browser session was handed, then cancels, leaving the
/// entitlement `pendingAuth` exactly as an abandoned authorization does.
private actor RecordingAuthorizer: AbilityAuthorizing {
    private(set) var urls: [String] = []

    func authorize(redirectUrl: String) async throws {
        urls.append(redirectUrl)
        throw OAuthError.cancelled
    }
}
