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

    // MARK: - Codex review regressions

    /// B1. The three-state opt-in model is a write rule as much as a
    /// render rule: an unsettled read must read as "unknown", never as
    /// "no opt-in here". Reading it as absent PUTs manifest defaults over
    /// a bundle selection the member already made.
    func testAutoEnableNeverOverwritesABundleSelectionItHasNotRead() async throws {
        let service = ScriptedAbilitiesService()
        await service.setOptIns([ConversationAbility(abilityId: "youtube", agentInboxId: agent.inboxId, bundleIds: ["youtube.library"])])
        await service.setConversationAbilitiesFailure(true)
        let viewModel = makeHostedViewModel(service: service)
        await service.setEntitlement(abilityId: "youtube", state: .entitled(try activeEntitlement()))
        await viewModel.refresh(adoptingCatalog: await service.currentCatalog())

        let unsettled = try row("youtube", in: viewModel)
        XCTAssertFalse(unsettled.hasSettledOptIn, "the read failed, so nothing is known about this chat")

        // The read recovers, and it says the member already opted in with
        // a custom selection.
        await service.setConversationAbilitiesFailure(false)
        viewModel.enableAfterConnect(abilityId: "youtube")
        try await settle { !viewModel.rows.contains { $0.ability.id == "youtube" && $0.isPendingEnablement } }

        let observedExtendB1 = await service.extendCount
        XCTAssertEqual(observedExtendB1, 0, "an existing selection is never overwritten with manifest defaults")
        let optIns = await service.currentOptIns()
        XCTAssertEqual(optIns.first { $0.abilityId == "youtube" }?.bundleIds, ["youtube.library"])
    }

    /// B1, second half: a read that stays down must refuse the write and
    /// say so, rather than guess.
    func testAutoEnableRefusesWhenTheOptInReadStaysDown() async throws {
        let service = ScriptedAbilitiesService()
        await service.setConversationAbilitiesFailure(true)
        let viewModel = makeHostedViewModel(service: service)
        await service.setEntitlement(abilityId: "youtube", state: .entitled(try activeEntitlement()))
        await viewModel.refresh(adoptingCatalog: await service.currentCatalog())

        viewModel.enableAfterConnect(abilityId: "youtube")
        try await settle { viewModel.errorMessage != nil }

        let observedExtendB1b = await service.extendCount
        XCTAssertEqual(observedExtendB1b, 0)
        XCTAssertFalse(try row("youtube", in: viewModel).isPendingEnablement)
    }

    /// B2. The host's catalog has to land on the spot. Queued behind an
    /// in-flight opt-in refresh, the rows stay sectioned by a catalog the
    /// screen has already replaced - long enough to write a grant against
    /// an outage it has already declared.
    func testAdoptedCatalogAppliesSynchronously() async throws {
        let service = ScriptedAbilitiesService()
        let viewModel = makeHostedViewModel(service: service)
        let live = await service.currentCatalog()
        await viewModel.refresh(adoptingCatalog: live)
        XCTAssertFalse(viewModel.entitlementsUnavailable)

        // A slow opt-in read is in flight when the outage catalog arrives.
        await service.setConversationAbilitiesDelay(.milliseconds(400))
        Task { await viewModel.refresh(adoptingCatalog: live) }
        try await Task.sleep(for: .milliseconds(20))

        let stale = AbilitiesCatalog(
            catalogVersion: live.catalogVersion,
            entitlementsUnavailable: true,
            abilities: live.abilities
        )
        viewModel.adoptCatalog(stale)

        XCTAssertTrue(viewModel.entitlementsUnavailable, "the outage is visible immediately, not after the queue drains")
        for row in viewModel.rows {
            XCTAssertTrue(viewModel.isToggleDisabled(for: row), "\(row.ability.id) stayed writable during a declared outage")
        }
    }

    /// B4. A connect completing while another mutation is in flight must
    /// not be swallowed by `extend`'s busy guard: Discover's Connect
    /// buttons stay tappable throughout, so this is reachable.
    func testAutoEnableWaitsForAnInFlightMutationInsteadOfBeingDropped() async throws {
        let service = ScriptedAbilitiesService()
        let viewModel = makeHostedViewModel(service: service)
        try await service.keepFirstBundleOnly(abilityId: "youtube")
        // Single-bundle on both sides, so each toggle-on extends straight
        // through instead of routing via the picker.
        try await service.keepFirstBundleOnly(abilityId: "googlecalendar")
        await service.setEntitlement(abilityId: "youtube", state: .entitled(try activeEntitlement()))
        await viewModel.refresh(adoptingCatalog: await service.currentCatalog())

        // Toggle googlecalendar on; its PUT is still landing.
        await service.setExtendDelay(.milliseconds(250))
        viewModel.toggle(try row("googlecalendar", in: viewModel))
        XCTAssertTrue(viewModel.isBusy)

        viewModel.enableAfterConnect(abilityId: "youtube")
        try await settle(timeout: .seconds(6)) { await service.extendCount == 2 }

        let optIns = await service.currentOptIns()
        XCTAssertTrue(optIns.contains { $0.abilityId == "youtube" }, "the auto-enable survived the busy window")
        XCTAssertTrue(optIns.contains { $0.abilityId == "googlecalendar" })
    }

    /// B5. `Row` is a value type, so clearing the pending set without
    /// rebuilding leaves the row on-and-busy until the trailing refetch
    /// returns - the spinner the settle-on-the-write rule exists to avoid.
    func testConfirmedWriteSettlesTheRowBeforeTheTrailingRefetchReturns() async throws {
        let service = ScriptedAbilitiesService()
        let viewModel = makeHostedViewModel(service: service)
        try await service.keepFirstBundleOnly(abilityId: "youtube")
        await service.setEntitlement(abilityId: "youtube", state: .entitled(try activeEntitlement()))
        await viewModel.refresh(adoptingCatalog: await service.currentCatalog())

        // The write confirms quickly; the opt-in refetch behind it stalls
        // for far longer than the settle budget below, so a row that waits
        // for the refetch cannot pass.
        await service.setConversationAbilitiesDelay(.milliseconds(2000))
        viewModel.enableAfterConnect(abilityId: "youtube")

        try await settle(timeout: .seconds(4)) { await service.extendCount == 1 }
        try await settle(timeout: .milliseconds(400)) {
            !viewModel.rows.contains { $0.ability.id == "youtube" && $0.isPendingEnablement }
        }
    }

    /// S2. A `pendingAuth` initiation with no redirect URL is a malformed
    /// response, not an auth-less ability. Reporting activation there
    /// asserts the opposite of what the server just said.
    func testPendingAuthWithoutARedirectUrlReportsNoActivation() async throws {
        var activated: [String] = []
        let viewModel = AbilitiesListViewModel(service: MalformedPendingAuthService())
        viewModel.onEntitlementActivated = { activated.append($0) }
        await viewModel.refresh()

        let ability = try XCTUnwrap(viewModel.availableAbilities.first)
        viewModel.connect(ability)
        try await settle { viewModel.errorMessage != nil }

        XCTAssertTrue(activated.isEmpty, "a pending entitlement never reports activation")
        XCTAssertNil(viewModel.pendingAuthorization, "and no authorization sheet is armed without a URL")
    }

    /// B3. The wipe has to land before the next line of the caller runs.
    /// Bumping it on a queued task leaves a window in which a fetch
    /// started under the wiped account can still commit.
    func testAccountWipeAdvancesTheSharedEpochSynchronously() {
        let before: UInt64 = AbilitiesAccountEpoch.shared.value
        AbilitiesServices.handleAccountDataWiped()
        XCTAssertEqual(AbilitiesAccountEpoch.shared.value, before &+ 1, "the epoch moved before this line ran")
    }

    /// B3, second half: a catalog fetched under the previous account must
    /// not commit once the epoch has moved on - even after a newer
    /// refresh has resynced the snapshot, which is what makes a
    /// "current epoch" check read true again.
    func testACatalogFetchedUnderAWipedAccountNeverCommits() async throws {
        let epoch = AbilitiesAccountEpoch()
        let service = GatedCatalogService()
        let viewModel = AbilitiesListViewModel(service: service, accountEpoch: epoch)
        await viewModel.refresh()
        let connecting = try XCTUnwrap(viewModel.availableAbilities.first)
        XCTAssertEqual(connecting.id, "account-a")

        // Connect's mid-flow quiet refresh is the fetch that stalls: it is
        // the one whose epoch guard used to be read after the await.
        await service.gateNextFetch()
        viewModel.connect(connecting)
        try await settle { await service.fetchCount == 2 }

        // The account is wiped, and a newer refresh resyncs the snapshot to
        // the new epoch - which is exactly what makes an "is the epoch
        // current now" check read true again for the stalled fetch.
        epoch.advance()
        await service.setMarker("account-b")
        await viewModel.refresh()
        XCTAssertEqual(viewModel.availableAbilities.first?.id, "account-b")

        // Only now does the pre-wipe fetch return.
        await service.releaseGate()
        try await settle { await service.fetchCount >= 3 || !viewModel.isBusy(connecting) }
        try await Task.sleep(for: .milliseconds(100))

        XCTAssertEqual(
            viewModel.availableAbilities.first?.id,
            "account-b",
            "a catalog fetched under the wiped account must not overwrite the current one"
        )
    }

    /// S1. Repair stays reachable during an outage on both surfaces: the
    /// spec explicitly refused to disable connect and repair there, and
    /// the conversation info view has always offered the tap. (The
    /// control's `.disabled` removal itself is a view-layer change; this
    /// pins the writer contract behind it.)
    func testRepairStaysAvailableDuringAnOutage() async throws {
        let service = ScriptedAbilitiesService()
        await service.setOptIns([ConversationAbility(abilityId: "coinbase", agentInboxId: agent.inboxId, bundleIds: ["coinbase.prices"])])
        let viewModel = ConversationAbilitiesViewModel(
            conversationId: conversationId,
            agents: [agent],
            selection: AbilitiesSelection(service: service),
            accountEpoch: AbilitiesAccountEpoch()
        )
        await service.serveEntitlementsUnavailable(true)
        await viewModel.refresh()

        XCTAssertTrue(viewModel.entitlementsUnavailable)
        let attention = try row("coinbase", in: viewModel)
        XCTAssertEqual(attention.lifecycle, .needsAttention(.expired), "an opt-in on a non-active entitlement needs repair")

        viewModel.presentConnect(for: attention)
        XCTAssertNotNil(viewModel.connectContext, "repair is never withheld by an outage")
    }

    // MARK: - Wiring

    /// B6. `@State` releases the per-chat view model the moment the modal
    /// is dismissed, but a connect already in flight still has to write
    /// its grant. The list view model outlives the dismissal through its
    /// own mutation task, so the activation callback has to carry the
    /// per-chat model with it.
    func testActivationWiringOutlivesTheModalDismissal() async throws {
        let service = ScriptedAbilitiesService()
        let listViewModel = AbilitiesListViewModel(service: service)
        weak var probe: ConversationAbilitiesViewModel?

        do {
            let conversationViewModel = makeHostedViewModel(service: service)
            probe = conversationViewModel
            AbilitiesListScreen.wireActivation(list: listViewModel, conversation: conversationViewModel)
        }

        XCTAssertNotNil(probe, "dismissing the modal must not strand a connect that has not written its grant")
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
    private var conversationAbilitiesDelay: Duration = .zero
    private var extendDelay: Duration = .zero

    func setConversationAbilitiesDelay(_ delay: Duration) {
        conversationAbilitiesDelay = delay
    }

    func setExtendDelay(_ delay: Duration) {
        extendDelay = delay
    }

    func fetchCatalog() async throws -> AbilitiesCatalog {
        catalogFetchCount += 1
        return AbilitiesCatalog(
            catalogVersion: 1,
            entitlementsUnavailable: servesEntitlementsUnavailable,
            abilities: abilities
        )
    }

    func currentOptIns() -> [ConversationAbility] {
        optIns
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
        if conversationAbilitiesDelay > .zero {
            try? await Task.sleep(for: conversationAbilitiesDelay)
        }
        if conversationAbilitiesFails {
            throw AbilitiesServiceError.accountRequired
        }
        return optIns
    }

    func extendAbility(conversationId: String, abilityId: String, agentInboxId: String, bundleIds: [String]) async throws {
        if extendDelay > .zero {
            try? await Task.sleep(for: extendDelay)
        }
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

/// One ability whose `beginEntitlement` answers `pendingAuth` without a
/// redirect URL - a malformed response, and the shape that used to fall
/// into the auth-less branch and report a false activation.
private actor MalformedPendingAuthService: AbilitiesServiceProtocol {
    func fetchCatalog() async throws -> AbilitiesCatalog {
        let ability = try AbilitiesAPI.Ability(
            id: "gmail",
            version: 1,
            displayName: AbilitiesAPI.LocalizedText(en: "Gmail"),
            subtitle: AbilitiesAPI.LocalizedText(en: "Read and send email"),
            auth: AbilitiesAPI.AbilityAuth(type: .oauth),
            bundles: [],
            entitlementState: .notEntitled
        )
        return AbilitiesCatalog(catalogVersion: 1, abilities: [ability])
    }

    func beginEntitlement(abilityId: String) async throws -> AbilityEntitlementInitiation {
        AbilityEntitlementInitiation(status: .pendingAuth, redirectUrl: nil)
    }

    func completeEntitlement(abilityId: String) async throws {}
    func revokeEntitlement(abilityId: String) async throws {}
    func conversationAbilities(conversationId: String) async throws -> [ConversationAbility] { [] }
    func extendAbility(conversationId: String, abilityId: String, agentInboxId: String, bundleIds: [String]) async throws {}
    func withdrawAbility(conversationId: String, abilityId: String, agentInboxId: String) async throws {}
}

/// A catalog service whose first fetch can be held open, so a response
/// captured under one account can be made to return after the account has
/// been wiped and a newer refresh has already committed.
private actor GatedCatalogService: AbilitiesServiceProtocol {
    private(set) var fetchCount: Int = 0
    private var marker: String = "account-a"
    private var gatedFetchIndex: Int?
    private var isGateReleased: Bool = false

    func gateNextFetch() {
        gatedFetchIndex = fetchCount + 1
        isGateReleased = false
    }

    func releaseGate() {
        isGateReleased = true
    }

    func setMarker(_ value: String) {
        marker = value
    }

    func fetchCatalog() async throws -> AbilitiesCatalog {
        fetchCount += 1
        let index: Int = fetchCount
        let servedMarker: String = marker
        if index == gatedFetchIndex {
            while !isGateReleased {
                try? await Task.sleep(for: .milliseconds(5))
            }
        }
        let ability = try AbilitiesAPI.Ability(
            id: servedMarker,
            version: 1,
            displayName: AbilitiesAPI.LocalizedText(en: servedMarker),
            subtitle: AbilitiesAPI.LocalizedText(en: servedMarker),
            auth: AbilitiesAPI.AbilityAuth(type: .none),
            bundles: [],
            entitlementState: .notEntitled
        )
        return AbilitiesCatalog(catalogVersion: 1, abilities: [ability])
    }

    func beginEntitlement(abilityId: String) async throws -> AbilityEntitlementInitiation {
        AbilityEntitlementInitiation(status: .active)
    }

    func completeEntitlement(abilityId: String) async throws {}
    func revokeEntitlement(abilityId: String) async throws {}
    func conversationAbilities(conversationId: String) async throws -> [ConversationAbility] { [] }
    func extendAbility(conversationId: String, abilityId: String, agentInboxId: String, bundleIds: [String]) async throws {}
    func withdrawAbility(conversationId: String, abilityId: String, agentInboxId: String) async throws {}
}
