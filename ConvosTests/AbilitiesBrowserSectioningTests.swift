@testable import Convos
import ConvosCore
import XCTest

/// The Connections browser's two-section split in `.composerModal`:
/// Connected holds every entitlement the account has in any lifecycle
/// state, Discover holds only authoritative not-entitled, and the outage
/// section holds the rest.
@MainActor
final class AbilitiesBrowserSectioningTests: XCTestCase {
    func testEntitledButNotActiveAbilitiesStayUnderConnected() async throws {
        let viewModel = AbilitiesListViewModel(service: MockAbilitiesService(scenario: .standard, artificialDelay: .zero))
        await viewModel.refresh()

        // The standard fixture: an active Google Calendar, a pendingAuth
        // Spotify and an expired Coinbase, all entitled.
        let connectedIds: [String] = viewModel.entitledAbilities.map(\.id)
        XCTAssertTrue(connectedIds.contains("googlecalendar"))
        XCTAssertTrue(connectedIds.contains("spotify"), "pendingAuth is still an entitlement the account holds")
        XCTAssertTrue(connectedIds.contains("coinbase"), "expired is still an entitlement the account holds")

        let discoverIds: [String] = viewModel.availableAbilities.map(\.id)
        XCTAssertFalse(discoverIds.contains("spotify"))
        XCTAssertFalse(discoverIds.contains("coinbase"))
        XCTAssertTrue(discoverIds.contains("youtube"))
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
