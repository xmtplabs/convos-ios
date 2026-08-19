@testable import Convos
import ConvosCore
import XCTest

/// The per-chat half of the Connections browser: a conversation view model
/// hosted by the list screen, which owns no catalog of its own, never
/// settles a toggle OFF on an unread state, and auto-enables what the
/// member just connected.
@MainActor
final class ConversationAbilitiesBrowserModeTests: XCTestCase {
    private enum TestError: Error {
        case rowNotFound(String)
    }

    private let agent: ConversationAgentDescriptor = ConversationAgentDescriptor(
        inboxId: "mock-agent-inbox-1",
        displayName: "Caley"
    )
    private let conversationId: String = "browser-conversation"

    private func makeHostedViewModel(
        service: ScriptedAbilitiesService,
        epoch: AbilitiesAccountEpoch = AbilitiesAccountEpoch()
    ) -> ConversationAbilitiesViewModel {
        ConversationAbilitiesViewModel(
            conversationId: conversationId,
            agents: [agent],
            selection: AbilitiesSelection(service: service),
            catalogSource: .hosted,
            accountEpoch: epoch
        )
    }

    private func row(_ abilityId: String, in viewModel: ConversationAbilitiesViewModel) throws -> ConversationAbilitiesViewModel.Row {
        guard let row = viewModel.rows.first(where: { $0.ability.id == abilityId }) else {
            throw TestError.rowNotFound(abilityId)
        }
        return row
    }

    // MARK: - Hosted catalog ownership

    /// A hosted view model must never fetch a catalog: a second fetch off
    /// the same actor at another moment can disagree with the one that
    /// sectioned the rows, and the toggle would then read a lifecycle from
    /// a snapshot the row was never placed by.
    func testHostedViewModelNeverFetchesItsOwnCatalog() async throws {
        let service = ScriptedAbilitiesService()
        let viewModel = makeHostedViewModel(service: service)

        await viewModel.refresh()
        let observedCatalogFetchCount = await service.catalogFetchCount
        XCTAssertEqual(observedCatalogFetchCount, 0)
        XCTAssertTrue(viewModel.rows.isEmpty, "no catalog, no rows")

        let catalog = await service.currentCatalog()
        await viewModel.refresh(adoptingCatalog: catalog)
        let observedCatalogFetchCount2 = await service.catalogFetchCount
        XCTAssertEqual(observedCatalogFetchCount2, 0, "the adopted catalog replaces the fetch entirely")
        XCTAssertFalse(viewModel.rows.isEmpty)
    }

    /// The invariant: a row entitled in the adopted catalog never renders a
    /// lifecycle derived from a different snapshot - so never
    /// `.needsEntitlement` or `.unknown`.
    func testAdoptedCatalogBacksEveryRowLifecycle() async throws {
        let service = ScriptedAbilitiesService()
        let viewModel = makeHostedViewModel(service: service)
        let catalog = await service.currentCatalog()

        // The service moves on underneath: a self-fetching view model would
        // pick this newer state up and disagree with the host's sections.
        await service.setEntitlement(abilityId: "googlecalendar", state: .notEntitled)
        await viewModel.refresh(adoptingCatalog: catalog)

        let entitledIds: [String] = catalog.abilities
            .filter { $0.entitlement?.status == .active }
            .map(\.id)
        XCTAssertFalse(entitledIds.isEmpty)
        for abilityId in entitledIds {
            let row = try row(abilityId, in: viewModel)
            XCTAssertEqual(row.lifecycle, .ready, "\(abilityId) is active in the sectioning catalog")
        }
    }

    /// Mutations must not pull in a catalog revision the host has not
    /// sectioned its rows from either.
    func testHostedMutationRefreshDoesNotFetchACatalog() async throws {
        let service = ScriptedAbilitiesService()
        let viewModel = makeHostedViewModel(service: service)
        await viewModel.refresh(adoptingCatalog: await service.currentCatalog())

        viewModel.extend(ability: try activeAbility("googlecalendar", in: viewModel), agent: agent, bundleIds: ["calendar.events"])
        try await settle { !viewModel.isBusy && viewModel.rows.contains { $0.ability.id == "googlecalendar" && $0.isOn } }

        let observedCatalogFetchCount3 = await service.catalogFetchCount
        XCTAssertEqual(observedCatalogFetchCount3, 0)
    }

    // MARK: - Opt-in read failure

    /// Loading and unavailable both render disabled, never a settled OFF:
    /// reading a failed fetch as "not enabled here" would invite a tap that
    /// extends with manifest defaults over a real selection.
    func testFailedOptInReadRendersDisabledRatherThanOff() async throws {
        let service = ScriptedAbilitiesService()
        await service.setConversationAbilitiesFailure(true)
        let viewModel = makeHostedViewModel(service: service)

        await viewModel.refresh(adoptingCatalog: await service.currentCatalog())

        let row = try row("googlecalendar", in: viewModel)
        XCTAssertFalse(row.hasSettledOptIn)
        XCTAssertTrue(viewModel.isToggleDisabled(for: row), "an unsettled opt-in read is never a settled OFF")
        XCTAssertNotNil(viewModel.errorMessage)
    }

    func testAuthoritativeOptInsSurviveAFailedRefresh() async throws {
        let service = ScriptedAbilitiesService()
        await service.setOptIns([ConversationAbility(abilityId: "googlecalendar", agentInboxId: agent.inboxId, bundleIds: ["calendar.events"])])
        let viewModel = makeHostedViewModel(service: service)
        let catalog = await service.currentCatalog()
        await viewModel.refresh(adoptingCatalog: catalog)

        XCTAssertTrue(try row("googlecalendar", in: viewModel).isOn)

        await service.setConversationAbilitiesFailure(true)
        await viewModel.refresh(adoptingCatalog: catalog)

        let row = try row("googlecalendar", in: viewModel)
        XCTAssertTrue(row.isOn, "the last authoritative set is replaced only by a successful one")
        XCTAssertTrue(row.hasSettledOptIn)
    }

    // MARK: - Outage

    /// While the catalog admits it cannot verify entitlement state, every
    /// per-chat control in the browser's Connected section is disabled and
    /// no tap writes a grant: a row can be sitting there on an entitlement
    /// revoked elsewhere since.
    func testOutageDisablesEveryToggleAndBlocksWrites() async throws {
        let service = ScriptedAbilitiesService()
        let viewModel = makeHostedViewModel(service: service)
        let live = await service.currentCatalog()
        let stale = AbilitiesCatalog(
            catalogVersion: live.catalogVersion,
            entitlementsUnavailable: true,
            abilities: live.abilities
        )
        await viewModel.refresh(adoptingCatalog: stale)

        XCTAssertTrue(viewModel.entitlementsUnavailable)
        XCTAssertFalse(viewModel.rows.isEmpty)
        for row in viewModel.rows {
            XCTAssertTrue(viewModel.isToggleDisabled(for: row), "\(row.ability.id) is toggleable during an outage")
        }

        viewModel.toggle(try row("googlecalendar", in: viewModel))
        try await Task.sleep(for: .milliseconds(50))
        let observedExtendCount = await service.extendCount
        XCTAssertEqual(observedExtendCount, 0)
        XCTAssertNil(viewModel.bundleSelection)
    }

    // MARK: - Auto-enable

    func testAutoEnableNeverShowsASettledOffFrame() async throws {
        let service = ScriptedAbilitiesService()
        let viewModel = makeHostedViewModel(service: service)
        await viewModel.refresh(adoptingCatalog: await service.currentCatalog())

        // youtube is catalog-only until the connect lands. One bundle, so
        // the auto-enable extends straight through without the picker.
        try await service.keepFirstBundleOnly(abilityId: "youtube")
        await service.setEntitlement(abilityId: "youtube", state: .entitled(try activeEntitlement()))
        viewModel.enableAfterConnect(abilityId: "youtube")

        // Immediately, before the write lands: on and busy, never off.
        let pending = try row("youtube", in: viewModel)
        XCTAssertTrue(pending.isOn)
        XCTAssertTrue(pending.isPendingEnablement)
        XCTAssertTrue(viewModel.isToggleDisabled(for: pending))

        try await settle { await service.extendCount == 1 }
        try await settle { !viewModel.rows.contains { $0.ability.id == "youtube" && $0.isPendingEnablement } }
        XCTAssertTrue(try row("youtube", in: viewModel).isOn, "the row settles on")
    }

    /// The activation callback carries an id, and the bundles are resolved
    /// from the freshest catalog: handing the pre-connect ability over
    /// would bounce straight back to Connect, since it still reads
    /// not-entitled.
    func testAutoEnableResolvesTheFreshAbilityRatherThanThePreConnectCopy() async throws {
        let service = ScriptedAbilitiesService()
        let viewModel = makeHostedViewModel(service: service)
        let preConnect = await service.currentCatalog()
        await viewModel.refresh(adoptingCatalog: preConnect)

        let staleRow = try row("youtube", in: viewModel)
        XCTAssertEqual(staleRow.lifecycle, .needsEntitlement, "the published copy still reads not-entitled")

        try await service.keepFirstBundleOnly(abilityId: "youtube")
        await service.setEntitlement(abilityId: "youtube", state: .entitled(try activeEntitlement()))
        viewModel.enableAfterConnect(abilityId: "youtube")

        try await settle { await service.extendCount == 1 }
        let observedLastExtend = await service.lastExtend
        let extended = try XCTUnwrap(observedLastExtend)
        XCTAssertEqual(extended.abilityId, "youtube")
        XCTAssertEqual(extended.bundleIds, ["youtube.search"], "manifest defaults off the refetched ability")
    }

    func testAutoEnableIsANoOpWhenAnOptInAlreadyExists() async throws {
        let service = ScriptedAbilitiesService()
        await service.setOptIns([ConversationAbility(abilityId: "googlecalendar", agentInboxId: agent.inboxId, bundleIds: ["calendar.availability"])])
        let viewModel = makeHostedViewModel(service: service)
        await viewModel.refresh(adoptingCatalog: await service.currentCatalog())

        viewModel.enableAfterConnect(abilityId: "googlecalendar")
        try await Task.sleep(for: .milliseconds(50))

        let observedExtendCount2 = await service.extendCount
        XCTAssertEqual(observedExtendCount2, 0, "an existing opt-in keeps its bundle selection")
    }

    // MARK: - Pending-enablement exits

    func testPendingEnablementClearsWhenTheExtendFails() async throws {
        let service = ScriptedAbilitiesService()
        await service.setExtendFailure(.transport)
        let viewModel = makeHostedViewModel(service: service)
        await viewModel.refresh(adoptingCatalog: await service.currentCatalog())
        try await service.keepFirstBundleOnly(abilityId: "youtube")
        await service.setEntitlement(abilityId: "youtube", state: .entitled(try activeEntitlement()))

        viewModel.enableAfterConnect(abilityId: "youtube")
        try await settle { !viewModel.rows.contains { $0.ability.id == "youtube" && $0.isPendingEnablement } }

        let row = try row("youtube", in: viewModel)
        XCTAssertFalse(row.isOn, "a failed extend settles the row off")
        XCTAssertNotNil(viewModel.errorMessage)
    }

    func testPendingEnablementClearsWhenTheExtendBouncesNeedsEntitlement() async throws {
        let service = ScriptedAbilitiesService()
        await service.setExtendFailure(.needsEntitlement)
        var repaired: [String] = []
        let viewModel = makeHostedViewModel(service: service)
        viewModel.entitlementRecoveryRoute = .host { ability in repaired.append(ability.id) }
        await viewModel.refresh(adoptingCatalog: await service.currentCatalog())
        try await service.keepFirstBundleOnly(abilityId: "youtube")
        await service.setEntitlement(abilityId: "youtube", state: .entitled(try activeEntitlement()))

        viewModel.enableAfterConnect(abilityId: "youtube")
        try await settle { !repaired.isEmpty }
        try await settle { !viewModel.rows.contains { $0.ability.id == "youtube" && $0.isPendingEnablement } }

        XCTAssertEqual(repaired, ["youtube"], "repair goes to the host's connect flow, not a second sheet")
        XCTAssertNil(viewModel.connectContext, "a hosted view model never arms its own connect sheet")
        XCTAssertFalse(try row("youtube", in: viewModel).isOn)
    }

    /// The exit with no shipped `onDismiss` before this change: a picker
    /// swiped away reports nothing, so the row would spin forever.
    func testPendingEnablementClearsWhenTheBundlePickerIsCancelled() async throws {
        let service = ScriptedAbilitiesService()
        let viewModel = makeHostedViewModel(service: service)
        await viewModel.refresh(adoptingCatalog: await service.currentCatalog())
        // The fixture ships youtube with two bundles, so the auto-enable
        // routes through the picker.
        await service.setEntitlement(abilityId: "youtube", state: .entitled(try activeEntitlement()))

        viewModel.enableAfterConnect(abilityId: "youtube")
        try await settle { viewModel.bundleSelection != nil }
        XCTAssertTrue(try row("youtube", in: viewModel).isPendingEnablement)

        // Swipe-away: SwiftUI nils the item, then calls onDismiss.
        viewModel.bundleSelection = nil
        viewModel.handleBundleSelectionDismissed()

        let row = try row("youtube", in: viewModel)
        XCTAssertFalse(row.isPendingEnablement, "a cancelled picker settles the row off")
        XCTAssertFalse(row.isOn)
        let observedExtendCount3 = await service.extendCount
        XCTAssertEqual(observedExtendCount3, 0)
    }

    func testConfirmingTheBundlePickerIsNotReadAsACancel() async throws {
        let service = ScriptedAbilitiesService()
        let viewModel = makeHostedViewModel(service: service)
        await viewModel.refresh(adoptingCatalog: await service.currentCatalog())
        await service.setEntitlement(abilityId: "youtube", state: .entitled(try activeEntitlement()))

        viewModel.enableAfterConnect(abilityId: "youtube")
        try await settle { viewModel.bundleSelection != nil }
        let context = try XCTUnwrap(viewModel.bundleSelection)

        viewModel.confirmBundleSelection(context, bundleIds: ["youtube.library"])
        viewModel.bundleSelection = nil
        viewModel.handleBundleSelectionDismissed()

        // The dismissal that follows a confirm is not the cancel exit: the
        // row must stay on and busy until the write lands.
        XCTAssertTrue(try row("youtube", in: viewModel).isPendingEnablement)

        try await settle { await service.extendCount == 1 }
        let observedLastExtend2 = await service.lastExtend
        let extended = try XCTUnwrap(observedLastExtend2)
        XCTAssertEqual(extended.bundleIds, ["youtube.library"])
        try await settle { viewModel.rows.contains { $0.ability.id == "youtube" && $0.isOn && !$0.isPendingEnablement } }
    }

    /// A zero-bundle ability returns before the extend ever runs, so the
    /// pending row has to be cleared on that path too.
    func testPendingEnablementClearsForAZeroBundleAbility() async throws {
        let service = ScriptedAbilitiesService()
        let viewModel = makeHostedViewModel(service: service)
        await viewModel.refresh(adoptingCatalog: await service.currentCatalog())
        await service.setEntitlement(abilityId: "youtube", state: .entitled(try activeEntitlement()))
        try await service.stripBundles(abilityId: "youtube")

        viewModel.enableAfterConnect(abilityId: "youtube")
        try await settle { viewModel.errorMessage != nil }

        let row = try row("youtube", in: viewModel)
        XCTAssertFalse(row.isPendingEnablement)
        XCTAssertFalse(row.isOn)
        let observedExtendCount4 = await service.extendCount
        XCTAssertEqual(observedExtendCount4, 0)
    }

    /// The conversation info view sections nothing by carried-forward
    /// state, so it keeps its shipped behavior: this addendum governs the
    /// browser, and silently freezing the info view's toggles would be a
    /// regression dressed as caution.
    func testOutageDoesNotWithholdTheInfoViewToggle() async throws {
        let service = ScriptedAbilitiesService()
        await service.setOptIns([ConversationAbility(abilityId: "googlecalendar", agentInboxId: agent.inboxId, bundleIds: ["calendar.events"])])
        let viewModel = ConversationAbilitiesViewModel(
            conversationId: conversationId,
            agents: [agent],
            selection: AbilitiesSelection(service: service),
            accountEpoch: AbilitiesAccountEpoch()
        )
        let live = await service.currentCatalog()
        await service.serveEntitlementsUnavailable(true)
        await viewModel.refresh()

        XCTAssertTrue(viewModel.entitlementsUnavailable)
        let row = try row("googlecalendar", in: viewModel)
        XCTAssertEqual(row.lifecycle, .ready, "last-known state carries the entitlement forward")
        XCTAssertFalse(viewModel.isToggleDisabled(for: row), "the info view toggle is not frozen by the browser's rule")
        XCTAssertFalse(live.entitlementsUnavailable)
    }

    // MARK: - Withdraw is per-chat only

    func testTogglingOffWithdrawsTheOptInAndLeavesTheEntitlementAlone() async throws {
        let service = ScriptedAbilitiesService()
        await service.setOptIns([ConversationAbility(abilityId: "googlecalendar", agentInboxId: agent.inboxId, bundleIds: ["calendar.events"])])
        let viewModel = makeHostedViewModel(service: service)
        let catalog = await service.currentCatalog()
        await viewModel.refresh(adoptingCatalog: catalog)

        viewModel.toggle(try row("googlecalendar", in: viewModel))
        try await settle { await service.withdrawCount == 1 }

        let observedRevokeCount = await service.revokeCount
        XCTAssertEqual(observedRevokeCount, 0, "toggling off is never an app-wide disconnect")
        let refreshed = await service.currentCatalog()
        let ability = try XCTUnwrap(refreshed.abilities.first { $0.id == "googlecalendar" })
        XCTAssertEqual(ability.entitlement?.status, .active, "the account still holds the entitlement")
    }

    /// The off-write is the shared control's single writer, so one broken
    /// path breaks both surfaces. Pinned from the info view's own
    /// (self-fetching) configuration as well as the browser's above.
    func testInfoViewTogglesAnActiveConnectionOff() async throws {
        let service = ScriptedAbilitiesService()
        await service.setOptIns([ConversationAbility(abilityId: "googlecalendar", agentInboxId: agent.inboxId, bundleIds: ["calendar.events"])])
        let viewModel = ConversationAbilitiesViewModel(
            conversationId: conversationId,
            agents: [agent],
            selection: AbilitiesSelection(service: service),
            accountEpoch: AbilitiesAccountEpoch()
        )
        await viewModel.refresh()

        let onRow = try row("googlecalendar", in: viewModel)
        XCTAssertTrue(onRow.isOn)
        XCTAssertEqual(onRow.lifecycle, .ready)
        XCTAssertFalse(viewModel.isToggleDisabled(for: onRow), "a settled ON row is tappable")

        viewModel.toggle(onRow)
        try await settle { await service.withdrawCount == 1 }
        try await settle { !viewModel.rows.contains { $0.ability.id == "googlecalendar" && $0.isOn } }

        let observedExtendCountOff = await service.extendCount
        XCTAssertEqual(observedExtendCountOff, 0, "toggling off never re-extends")
        let observedRevokeCountOff = await service.revokeCount
        XCTAssertEqual(observedRevokeCountOff, 0, "and never disconnects app-wide")
    }

    // MARK: - Account epoch

    /// A wipe notifies no view model, so a modal open across one would keep
    /// rendering the previous account's connections and accept a toggle
    /// against them.
    func testAccountWipeDropsTheSnapshotAndBlocksWrites() async throws {
        let epoch = AbilitiesAccountEpoch()
        let service = ScriptedAbilitiesService()
        await service.setOptIns([ConversationAbility(abilityId: "googlecalendar", agentInboxId: agent.inboxId, bundleIds: ["calendar.events"])])
        let viewModel = makeHostedViewModel(service: service, epoch: epoch)
        await viewModel.refresh(adoptingCatalog: await service.currentCatalog())

        let staleRow = try row("googlecalendar", in: viewModel)
        XCTAssertTrue(staleRow.isOn)

        epoch.advance()

        XCTAssertTrue(viewModel.rows.isEmpty, "the previous account's connections stop rendering")
        viewModel.toggle(staleRow)
        try await Task.sleep(for: .milliseconds(50))
        let observedWithdrawCount = await service.withdrawCount
        XCTAssertEqual(observedWithdrawCount, 0, "a toggle tap must not write against them")
        let observedExtendCount5 = await service.extendCount
        XCTAssertEqual(observedExtendCount5, 0)
    }

    func testAccountWipeAlsoEmptiesTheListViewModel() async throws {
        let epoch = AbilitiesAccountEpoch()
        let viewModel = AbilitiesListViewModel(
            service: MockAbilitiesService(scenario: .standard, artificialDelay: .zero),
            accountEpoch: epoch
        )
        await viewModel.refresh()
        XCTAssertFalse(viewModel.entitledAbilities.isEmpty)

        epoch.advance()

        XCTAssertTrue(viewModel.entitledAbilities.isEmpty)
        XCTAssertTrue(viewModel.availableAbilities.isEmpty)
        XCTAssertFalse(viewModel.hasLoadedOnce)
    }

    // MARK: - Activation reporting

    /// All three connect completion sites report the activation, and the
    /// stub-sheet path waits for the sheet's own dismissal - nilling
    /// `pendingAuthorization` is not proof of it.
    func testAuthLessConnectReportsItsActivation() async throws {
        var activated: [String] = []
        let viewModel = AbilitiesListViewModel(service: AuthLessAbilitiesService())
        viewModel.onEntitlementActivated = { activated.append($0) }
        await viewModel.refresh()

        let ability = try XCTUnwrap(viewModel.availableAbilities.first)
        viewModel.connect(ability)
        try await settle { !activated.isEmpty }

        XCTAssertEqual(activated, [ability.id], "an auth-less ability goes active on begin alone")
    }

    func testStubSheetActivationWaitsForTheSheetDismissal() async throws {
        var activated: [String] = []
        let service = MockAbilitiesService(scenario: .standard, artificialDelay: .zero)
        let viewModel = AbilitiesListViewModel(service: service)
        viewModel.onEntitlementActivated = { activated.append($0) }
        await viewModel.refresh()

        let youtube = try XCTUnwrap(viewModel.availableAbilities.first { $0.id == "youtube" })
        viewModel.connect(youtube)
        try await settle { viewModel.pendingAuthorization != nil }

        let context = try XCTUnwrap(viewModel.pendingAuthorization)
        viewModel.completeAuthorization(context)
        try await settle { !viewModel.isBusy(youtube) }
        XCTAssertTrue(activated.isEmpty, "pendingAuthorization == nil is not proof the sheet dismissed")

        viewModel.handleAuthorizationDismissed()
        XCTAssertEqual(activated, ["youtube"])

        viewModel.handleAuthorizationDismissed()
        XCTAssertEqual(activated, ["youtube"], "released exactly once")
    }

    // MARK: - Helpers

    private func activeEntitlement() throws -> AbilitiesAPI.Entitlement {
        try AbilitiesAPI.Entitlement(status: .active, expiresAt: nil, extensionCount: 0)
    }

    private func activeAbility(_ abilityId: String, in viewModel: ConversationAbilitiesViewModel) throws -> AbilitiesAPI.Ability {
        try row(abilityId, in: viewModel).ability
    }

    /// Polls `condition` on the main actor until it holds, so a
    /// fire-and-forget view-model task can land without a fixed sleep.
    private func settle(
        timeout: Duration = .seconds(3),
        _ condition: @MainActor () async -> Bool
    ) async throws {
        let deadline = ContinuousClock.now.advanced(by: timeout)
        while ContinuousClock.now < deadline {
            if await condition() { return }
            try await Task.sleep(for: .milliseconds(5))
        }
        XCTFail("condition never settled")
    }
}

/// A catalog-and-opt-ins service the tests drive directly: it counts every
/// call, so "the hosted view model never fetches a catalog" is a fact the
/// test can assert rather than infer.
private actor ScriptedAbilitiesService: AbilitiesServiceProtocol {
    enum ExtendFailure {
        case transport
        case needsEntitlement
    }

    struct ExtendRecord {
        let abilityId: String
        let agentInboxId: String
        let bundleIds: [String]
    }

    private(set) var catalogFetchCount: Int = 0
    private(set) var extendCount: Int = 0
    private(set) var withdrawCount: Int = 0
    private(set) var revokeCount: Int = 0
    private(set) var lastExtend: ExtendRecord?

    private var abilities: [AbilitiesAPI.Ability] = MockAbilitiesService.standardCatalog()
    private var optIns: [ConversationAbility] = []
    private var conversationAbilitiesFails: Bool = false
    private var extendFailure: ExtendFailure?
    private var servesEntitlementsUnavailable: Bool = false

    func fetchCatalog() async throws -> AbilitiesCatalog {
        catalogFetchCount += 1
        return AbilitiesCatalog(
            catalogVersion: 1,
            entitlementsUnavailable: servesEntitlementsUnavailable,
            abilities: abilities
        )
    }

    /// The catalog without counting it as a view-model fetch: the tests use
    /// this to stand in for what the host already owns.
    func currentCatalog() -> AbilitiesCatalog {
        AbilitiesCatalog(catalogVersion: 1, abilities: abilities)
    }

    func setEntitlement(abilityId: String, state: AbilitiesAPI.EntitlementState) {
        abilities = abilities.map { $0.id == abilityId ? $0.withEntitlementState(state) : $0 }
    }

    func setOptIns(_ values: [ConversationAbility]) {
        optIns = values
    }

    func setConversationAbilitiesFailure(_ fails: Bool) {
        conversationAbilitiesFails = fails
    }

    func serveEntitlementsUnavailable(_ unavailable: Bool) {
        servesEntitlementsUnavailable = unavailable
    }

    func setExtendFailure(_ failure: ExtendFailure?) {
        extendFailure = failure
    }

    /// The fixture ships two bundles per ability, which routes a toggle-on
    /// through the picker; a single-bundle ability extends straight through.
    func keepFirstBundleOnly(abilityId: String) throws {
        try replaceBundles(abilityId: abilityId) { Array($0.prefix(1)) }
    }

    func stripBundles(abilityId: String) throws {
        try replaceBundles(abilityId: abilityId) { _ in [] }
    }

    private func replaceBundles(
        abilityId: String,
        _ transform: ([AbilitiesAPI.AbilityBundle]) -> [AbilitiesAPI.AbilityBundle]
    ) throws {
        abilities = try abilities.map { (ability: AbilitiesAPI.Ability) -> AbilitiesAPI.Ability in
            guard ability.id == abilityId else { return ability }
            return try AbilitiesAPI.Ability(
                id: ability.id,
                version: ability.version,
                displayName: ability.displayName,
                subtitle: ability.subtitle,
                icon: ability.icon,
                auth: ability.auth,
                bundles: transform(ability.bundles),
                entitlementState: ability.entitlementState
            )
        }
    }

    func beginEntitlement(abilityId: String) async throws -> AbilityEntitlementInitiation {
        throw AbilitiesServiceError.accountRequired
    }

    func completeEntitlement(abilityId: String) async throws {
        throw AbilitiesServiceError.accountRequired
    }

    func revokeEntitlement(abilityId: String) async throws {
        revokeCount += 1
    }

    func conversationAbilities(conversationId: String) async throws -> [ConversationAbility] {
        if conversationAbilitiesFails {
            throw AbilitiesServiceError.accountRequired
        }
        return optIns
    }

    func extendAbility(conversationId: String, abilityId: String, agentInboxId: String, bundleIds: [String]) async throws {
        switch extendFailure {
        case .transport:
            throw AbilitiesServiceError.accountRequired
        case .needsEntitlement:
            throw AbilitiesServiceError.needsEntitlement(abilityId: abilityId)
        case .none:
            break
        }
        extendCount += 1
        lastExtend = ExtendRecord(abilityId: abilityId, agentInboxId: agentInboxId, bundleIds: bundleIds)
        optIns.removeAll { $0.abilityId == abilityId && $0.agentInboxId == agentInboxId }
        optIns.append(ConversationAbility(abilityId: abilityId, agentInboxId: agentInboxId, bundleIds: bundleIds))
    }

    func withdrawAbility(conversationId: String, abilityId: String, agentInboxId: String) async throws {
        withdrawCount += 1
        optIns.removeAll { $0.abilityId == abilityId && $0.agentInboxId == agentInboxId }
    }
}

/// One ability whose manifest needs no authorization: `beginEntitlement`
/// returns active, and the `pendingAuth` branch never runs for it.
private actor AuthLessAbilitiesService: AbilitiesServiceProtocol {
    private var isEntitled: Bool = false

    func fetchCatalog() async throws -> AbilitiesCatalog {
        let entitlementState: AbilitiesAPI.EntitlementState = isEntitled
            ? .entitled(try AbilitiesAPI.Entitlement(status: .active, expiresAt: nil, extensionCount: 0))
            : .notEntitled
        let ability = try AbilitiesAPI.Ability(
            id: "weather",
            version: 1,
            displayName: AbilitiesAPI.LocalizedText(en: "Weather"),
            subtitle: AbilitiesAPI.LocalizedText(en: "Forecasts"),
            auth: AbilitiesAPI.AbilityAuth(type: .none),
            bundles: [],
            entitlementState: entitlementState
        )
        return AbilitiesCatalog(catalogVersion: 1, abilities: [ability])
    }

    func beginEntitlement(abilityId: String) async throws -> AbilityEntitlementInitiation {
        isEntitled = true
        return AbilityEntitlementInitiation(status: .active)
    }

    func completeEntitlement(abilityId: String) async throws {}

    func revokeEntitlement(abilityId: String) async throws {
        isEntitled = false
    }

    func conversationAbilities(conversationId: String) async throws -> [ConversationAbility] {
        []
    }

    func extendAbility(conversationId: String, abilityId: String, agentInboxId: String, bundleIds: [String]) async throws {}

    func withdrawAbility(conversationId: String, abilityId: String, agentInboxId: String) async throws {}
}
