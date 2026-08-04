@testable import Convos
import ConvosCore
import XCTest

/// Covers the inline connect flow the conversation abilities toggles drive
/// when an ability has no active entitlement: presenting the connect
/// sheet, the cancel path reverting cleanly, and the post-connect
/// continuation into the extension.
@MainActor
final class ConversationAbilitiesViewModelTests: XCTestCase {
    private enum TestError: Error {
        case rowNotFound(String)
        case abilityNotFound(String)
    }

    private let agent: ConversationAgentDescriptor = ConversationAgentDescriptor(
        inboxId: "mock-agent-inbox-1",
        displayName: "Caley"
    )

    private func makeViewModel(
        service: MockAbilitiesService,
        conversationId: String = "test-conversation"
    ) async -> ConversationAbilitiesViewModel {
        let viewModel = ConversationAbilitiesViewModel(
            conversationId: conversationId,
            agents: [agent],
            selection: AbilitiesSelection(service: service)
        )
        await viewModel.refresh()
        return viewModel
    }

    private func row(_ abilityId: String, in viewModel: ConversationAbilitiesViewModel) throws -> ConversationAbilitiesViewModel.Row {
        guard let row = viewModel.rows.first(where: { $0.ability.id == abilityId }) else {
            throw TestError.rowNotFound(abilityId)
        }
        return row
    }

    /// Connects `abilityId` directly on the mock service (begin, complete)
    /// and returns the refreshed ability with its now-active entitlement,
    /// the way `AbilityConnectSheet` reports success.
    private func connectOnService(_ service: MockAbilitiesService, abilityId: String) async throws -> AbilitiesAPI.Ability {
        _ = try await service.beginEntitlement(abilityId: abilityId)
        try await service.completeEntitlement(abilityId: abilityId)
        let catalog = try await service.fetchCatalog()
        guard let refreshed = catalog.abilities.first(where: { $0.id == abilityId }) else {
            throw TestError.abilityNotFound(abilityId)
        }
        XCTAssertEqual(refreshed.entitlement?.status, .active)
        return refreshed
    }

    /// Waits for the view model's fire-and-forget extension task to land in
    /// the service, returning the opt-ins once `predicate` passes.
    private func waitForConversationAbilities(
        service: MockAbilitiesService,
        conversationId: String,
        where predicate: ([ConversationAbility]) -> Bool
    ) async throws -> [ConversationAbility] {
        for _ in 0..<200 {
            let optIns = try await service.conversationAbilities(conversationId: conversationId)
            if predicate(optIns) {
                return optIns
            }
            try await Task.sleep(for: .milliseconds(10))
        }
        return try await service.conversationAbilities(conversationId: conversationId)
    }

    func testToggleWithoutEntitlementPresentsConnectSheet() async throws {
        let service = MockAbilitiesService(scenario: .standard, artificialDelay: .zero)
        let viewModel = await makeViewModel(service: service)

        let youtubeRow = try row("youtube", in: viewModel)
        XCTAssertEqual(youtubeRow.lifecycle, .needsEntitlement)
        XCTAssertFalse(youtubeRow.isOn)

        viewModel.toggle(youtubeRow)

        let context = try XCTUnwrap(viewModel.connectContext)
        XCTAssertEqual(context.ability.id, "youtube")
        XCTAssertEqual(context.agent, agent)
        XCTAssertTrue(context.continuesToExtension)
        XCTAssertNil(context.preselectedBundleIds)
        XCTAssertNil(viewModel.bundleSelection)
    }

    func testConnectSheetCancelRevertsWithoutExtension() async throws {
        let service = MockAbilitiesService(scenario: .standard, artificialDelay: .zero)
        let viewModel = await makeViewModel(service: service)

        viewModel.toggle(try row("youtube", in: viewModel))
        XCTAssertNotNil(viewModel.connectContext)

        // Cancel: the sheet dismisses without ever reporting a connect.
        viewModel.connectContext = nil
        viewModel.handleConnectSheetDismissed()
        await viewModel.refresh()

        XCTAssertNil(viewModel.connectContext)
        XCTAssertNil(viewModel.bundleSelection)
        let youtubeRow = try row("youtube", in: viewModel)
        XCTAssertFalse(youtubeRow.isOn)
        let optIns = try await service.conversationAbilities(conversationId: "test-conversation")
        XCTAssertFalse(optIns.contains { $0.abilityId == "youtube" })
    }

    func testConnectedContinuesIntoBundlePickerForMultiBundleAbility() async throws {
        let service = MockAbilitiesService(scenario: .standard, artificialDelay: .zero)
        let viewModel = await makeViewModel(service: service)

        viewModel.toggle(try row("youtube", in: viewModel))
        let refreshed = try await connectOnService(service, abilityId: "youtube")

        viewModel.handleConnected(refreshed)
        XCTAssertNil(viewModel.connectContext, "success dismisses the connect sheet")

        viewModel.handleConnectSheetDismissed()
        let bundleSelection = try XCTUnwrap(viewModel.bundleSelection, "multi-bundle ability continues into the picker")
        XCTAssertEqual(bundleSelection.ability.id, "youtube")
        XCTAssertEqual(bundleSelection.ability.entitlement?.status, .active)
        XCTAssertEqual(bundleSelection.agent, agent)
    }

    func testConnectedExtendsDirectlyWithPreselectedBundles() async throws {
        let service = MockAbilitiesService(scenario: .standard, artificialDelay: .zero)
        let viewModel = await makeViewModel(service: service)

        // The extend-bounced shape: bundles were already chosen when the
        // server reported the missing entitlement.
        let stale = try row("youtube", in: viewModel).ability
        viewModel.connectContext = ConversationAbilityConnectContext(
            ability: stale,
            agent: agent,
            continuesToExtension: true,
            preselectedBundleIds: ["youtube.search"]
        )
        let refreshed = try await connectOnService(service, abilityId: "youtube")

        viewModel.handleConnected(refreshed)
        viewModel.handleConnectSheetDismissed()

        let optIns = try await waitForConversationAbilities(service: service, conversationId: "test-conversation") { rows in
            rows.contains { $0.abilityId == "youtube" }
        }
        let optIn = try XCTUnwrap(optIns.first { $0.abilityId == "youtube" })
        XCTAssertEqual(optIn.bundleIds, ["youtube.search"])
        XCTAssertNil(viewModel.bundleSelection, "preselected bundles skip the picker")

        await viewModel.refresh()
        XCTAssertTrue(try row("youtube", in: viewModel).isOn)
    }

    func testReconnectOfOptedInRowDoesNotOverwriteBundleSelection() async throws {
        let service = MockAbilitiesService(scenario: .standard, artificialDelay: .zero)
        // Standard fixture: coinbase is opted in here with an expired
        // entitlement, so its row needs attention rather than a toggle.
        let conversationId = "mock-conversation-1"
        let viewModel = await makeViewModel(service: service, conversationId: conversationId)

        let coinbaseRow = try row("coinbase", in: viewModel)
        XCTAssertTrue(coinbaseRow.isOn)
        XCTAssertEqual(coinbaseRow.lifecycle, .needsAttention(.expired))

        viewModel.presentConnect(for: coinbaseRow)
        let context = try XCTUnwrap(viewModel.connectContext)
        XCTAssertFalse(context.continuesToExtension, "an existing opt-in only repairs the entitlement")

        let refreshed = try await connectOnService(service, abilityId: "coinbase")
        viewModel.handleConnected(refreshed)
        viewModel.handleConnectSheetDismissed()
        await viewModel.refresh()

        XCTAssertNil(viewModel.bundleSelection)
        let optIns = try await service.conversationAbilities(conversationId: conversationId)
        let optIn = try XCTUnwrap(optIns.first { $0.abilityId == "coinbase" })
        XCTAssertEqual(optIn.bundleIds, ["coinbase.prices"], "the original bundle selection survives the reconnect")
        XCTAssertEqual(try row("coinbase", in: viewModel).lifecycle, .ready)
    }
}
