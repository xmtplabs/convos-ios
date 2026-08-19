@testable import Convos
import ConvosCore
import XCTest

/// The hero is the first thing the composer's powerplug shows, so it must
/// never claim "nothing connected yet" on state the app knows is stale.
@MainActor
final class AbilitiesListHeroVisibilityTests: XCTestCase {
    func testHeroShowsWhenNothingIsEntitledAndStateIsAuthoritative() async {
        let viewModel = AbilitiesListViewModel(service: MockAbilitiesService(scenario: .deviceOnly, artificialDelay: .zero))
        await viewModel.refresh()

        XCTAssertFalse(viewModel.entitlementsUnavailable)
        XCTAssertTrue(viewModel.entitledAbilities.isEmpty)
        XCTAssertFalse(viewModel.availableAbilities.isEmpty)
        XCTAssertTrue(viewModel.showsNothingConnectedHero)
    }

    func testHeroIsWithheldWhenEntitlementStateIsUnavailable() async {
        let viewModel = AbilitiesListViewModel(service: StaleOutageAbilitiesService())
        await viewModel.refresh()

        // The trap this pins: an outage whose last-known state held nothing
        // leaves the hero's other four terms all true.
        XCTAssertTrue(viewModel.entitlementsUnavailable)
        XCTAssertTrue(viewModel.hasLoadedOnce)
        XCTAssertFalse(viewModel.isSearching)
        XCTAssertTrue(viewModel.entitledAbilities.isEmpty)
        XCTAssertFalse(viewModel.availableAbilities.isEmpty)

        XCTAssertFalse(viewModel.showsNothingConnectedHero)
    }

    func testHeroIsWithheldWhileSearching() async {
        let viewModel = AbilitiesListViewModel(service: MockAbilitiesService(scenario: .deviceOnly, artificialDelay: .zero))
        await viewModel.refresh()
        viewModel.searchText = "cal"

        XCTAssertTrue(viewModel.isSearching)
        XCTAssertFalse(viewModel.showsNothingConnectedHero)
    }

    func testHeroIsWithheldBeforeTheCatalogLoads() {
        let viewModel = AbilitiesListViewModel(service: MockAbilitiesService(scenario: .deviceOnly, artificialDelay: .zero))

        XCTAssertFalse(viewModel.hasLoadedOnce)
        XCTAssertFalse(viewModel.showsNothingConnectedHero)
    }
}

/// Entitlement lookup is down and the last-known state it carries forward
/// held no entitlements - the one shape no `MockAbilitiesService` scenario
/// produces, and the exact shape that makes the hero lie.
private struct StaleOutageAbilitiesService: AbilitiesServiceProtocol {
    func fetchCatalog() async throws -> AbilitiesCatalog {
        AbilitiesCatalog(
            catalogVersion: 1,
            entitlementsUnavailable: true,
            abilities: MockAbilitiesService.standardCatalog().map { $0.withEntitlementState(.notEntitled) }
        )
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
