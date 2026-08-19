import Combine
@testable import Convos
import ConvosConnections
import ConvosCore
import XCTest

/// Covers the transcript connect pill's view-model seam: the tap handler
/// gating, the auto-dismiss tie between the pending layout and the approval
/// sheet, the connect-before-grant sequencing for providers that aren't
/// linked yet, and the shared layout computation that must always resolve the
/// services catalog (the OAuth-error recompute path used to omit it, dropping
/// bundle rows so an approve silently escalated to full-service consent).
@MainActor
final class ConversationViewModelCapabilityConnectTests: XCTestCase {
    func testComputeCapabilityPickerLayoutPopulatesBundleRows() async throws {
        let registry = InMemoryCapabilityProviderRegistry()
        await registry.register(
            CloudCapabilityProvider(
                id: ProviderID(rawValue: "composio.googlecalendar"),
                serviceId: "googlecalendar",
                subject: .calendar,
                displayName: "Google Calendar",
                iconName: "calendar",
                capabilities: [.read, .writeCreate, .writeUpdate, .writeDelete],
                linked: true
            )
        )
        let resolver = InMemoryCapabilityResolver(registry: registry)
        let servicesStore = ConnectionServicesStore(fetchServices: {
            CloudConnectionsAPI.ServicesResponse(services: [
                .init(
                    id: "googlecalendar",
                    composioSlug: "googlecalendar",
                    version: 5,
                    displayName: .init(values: ["en": "Google Calendar"]),
                    bundles: [
                        .init(
                            id: "calendar.events",
                            title: .init(values: ["en": "Events"]),
                            description: .init(values: ["en": "View and edit events on all calendars"]),
                            defaultEnabled: false
                        ),
                    ]
                ),
            ])
        })

        // Awaited into a local first: `XCTUnwrap` takes an autoclosure, which
        // cannot carry an `await`.
        let computedLayout = await ConversationViewModel.computeCapabilityPickerLayout(
            request: makeRequest(),
            registry: registry,
            resolver: resolver,
            handler: CapabilityRequestHandler(),
            servicesStore: servicesStore,
            cloudConnectionRepository: MockConnectionRepository(),
            conversationId: "test-convo"
        )
        let layout = try XCTUnwrap(computedLayout)

        XCTAssertEqual(layout.serviceBundles.count, 1,
                       "Catalog-backed services must surface their bundle rows")
        XCTAssertEqual(layout.serviceBundles.first?.serviceId, "googlecalendar")
        let rows = layout.serviceBundles.first?.rows ?? []
        XCTAssertFalse(rows.isEmpty,
                       "Empty bundle rows would silently escalate an approve to full-service consent")
        XCTAssertEqual(rows.map(\.id), ["calendar.events"])
    }

    func testTapPendingPromptPresentsApprovalSheet() {
        let viewModel = makeViewModel()
        viewModel.pendingCapabilityPickerLayout = makeLayout(requestId: "req-1")

        viewModel.onTapCapabilityConnectPrompt(makePrompt(requestId: "req-1", status: .pending))

        XCTAssertTrue(viewModel.presentingCapabilityApproval)
    }

    func testTapConnectedPromptIsInert() {
        let viewModel = makeViewModel()
        viewModel.pendingCapabilityPickerLayout = makeLayout(requestId: "req-1")

        viewModel.onTapCapabilityConnectPrompt(makePrompt(requestId: "req-1", status: .connected))

        XCTAssertFalse(viewModel.presentingCapabilityApproval)
    }

    func testTapSupersededPromptIsInert() {
        let viewModel = makeViewModel()
        viewModel.pendingCapabilityPickerLayout = makeLayout(requestId: "req-2")

        viewModel.onTapCapabilityConnectPrompt(makePrompt(requestId: "req-1", status: .superseded))

        XCTAssertFalse(viewModel.presentingCapabilityApproval,
                       "Superseded pills derive a non-pending status and stay inert")
    }

    func testTapPendingPromptWithMismatchedLayoutIsInert() {
        // Race guard: the derivation re-renders asynchronously, so a pill can
        // still read `.pending` for one frame after the layout moved on (e.g.
        // locally answered request). The layout-match guard must absorb that.
        let viewModel = makeViewModel()
        viewModel.pendingCapabilityPickerLayout = makeLayout(requestId: "req-2")

        viewModel.onTapCapabilityConnectPrompt(makePrompt(requestId: "req-1", status: .pending))

        XCTAssertFalse(viewModel.presentingCapabilityApproval,
                       "Only the request backing the pending layout is actionable")
    }

    func testClearingLayoutDismissesApprovalSheet() {
        let viewModel = makeViewModel()
        viewModel.pendingCapabilityPickerLayout = makeLayout(requestId: "req-1")
        viewModel.onTapCapabilityConnectPrompt(makePrompt(requestId: "req-1", status: .pending))
        XCTAssertTrue(viewModel.presentingCapabilityApproval)

        viewModel.pendingCapabilityPickerLayout = nil

        XCTAssertFalse(viewModel.presentingCapabilityApproval,
                       "Resolving the request elsewhere must close the sheet")
    }

    // MARK: - Connect-before-grant (pre-connect approvals)

    func testApproveLinkedProviderResolvesAfterScopeCheck() async {
        let viewModel = makeViewModel()
        viewModel.pendingCapabilityPickerLayout = makeLayout(requestId: "req-1")

        viewModel.onCapabilityApprove(
            providerIds: [ProviderID(rawValue: "composio.googlecalendar")],
            bundleSelection: ["googlecalendar": ["calendar.events"]]
        )

        // The approve pipeline runs after the async grant-scope consistency
        // check; no connect step is needed, so the layout then clears.
        await waitUntil { viewModel.pendingCapabilityPickerLayout == nil }
        XCTAssertNil(viewModel.pendingCapabilityPickerLayout,
                     "No connect step needed — the approval resolves after the scope check")
    }

    func testLateTapResolutionCannotRepaintAfterApproveDivergence() async throws {
        let stub = StubScopeRepository(initial: CapabilityGrantScopeResolution(
            scope: .originGroup("origin-a"),
            scopeDisplayName: "Group A"
        ))
        let session = MockInboxesService()
        session.capabilityRequestRepositoryOverride = stub
        let viewModel = ConversationViewModel(
            conversation: .mock(id: "test-convo"),
            session: session,
            messagingService: MockMessagingService(),
            applyGlobalDefaultsForNewConversation: false
        )
        // Let the view model's init-time mock emissions (conversation update,
        // capability-request observation reset) settle before arranging state
        // by hand -- they clear the capability fields asynchronously.
        try await Task.sleep(for: .milliseconds(200))
        viewModel.pendingCapabilityPickerLayout = makeLayout(requestId: "req-1")

        // First tap discloses scope A on the sheet.
        viewModel.onTapCapabilityConnectPrompt(makePrompt(requestId: "req-1", status: .pending))
        await waitUntil { stub.callCount >= 1 }
        XCTAssertGreaterThanOrEqual(stub.callCount, 1, "The tap must reach the injected scope resolver")
        await waitUntil { viewModel.capabilityGrantScopeResolution?.scopeDisplayName == "Group A" }
        XCTAssertEqual(viewModel.capabilityGrantScopeResolution?.scopeDisplayName, "Group A",
                       "The first tap must disclose scope A before the race is arranged")

        // Second tap parks inside the resolver while it still reads scope A.
        stub.setGated(true)
        viewModel.onTapCapabilityConnectPrompt(makePrompt(requestId: "req-1", status: .pending))
        await waitUntil { stub.waiterCount == 1 }
        XCTAssertEqual(stub.waiterCount, 1, "The second tap's resolution must park in the gate")

        // The origin moves: new resolutions now return scope B; the approve
        // tap re-resolves, sees B against the disclosed A, and refuses.
        stub.setGated(false)
        stub.setResult(CapabilityGrantScopeResolution(
            scope: .originGroup("origin-b"),
            scopeDisplayName: "Group B"
        ))
        viewModel.onCapabilityApprove(
            providerIds: [ProviderID(rawValue: "composio.googlecalendar")],
            bundleSelection: ["googlecalendar": ["calendar.events"]]
        )
        await waitUntil { viewModel.capabilityApprovalErrorMessage != nil }
        XCTAssertEqual(viewModel.capabilityGrantScopeResolution?.scopeDisplayName, "Group B")
        XCTAssertNotNil(viewModel.pendingCapabilityPickerLayout,
                        "A diverged approval must not consume the request")

        // The parked tap resolution lands last carrying stale scope A. The
        // generation guard must drop it -- otherwise the sheet silently
        // reverts to A and the user's retry diverges forever.
        stub.releaseAll()
        await waitUntil { stub.waiterCount == 0 }
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(viewModel.capabilityGrantScopeResolution?.scopeDisplayName, "Group B",
                       "The divergence re-present must win over the stale tap resolution")
    }

    func testApproveUnlinkedProviderConnectsBeforeSendingResult() async {
        let viewModel = makeViewModel()
        viewModel.pendingCapabilityPickerLayout = makeLayout(
            requestId: "req-1",
            variant: .connectAndApprove,
            linked: false
        )

        viewModel.onCapabilityApprove(
            providerIds: [ProviderID(rawValue: "composio.googlecalendar")],
            bundleSelection: ["googlecalendar": ["calendar.events"]]
        )

        XCTAssertNotNil(viewModel.pendingCapabilityPickerLayout,
                        "The grant must wait for the connect step — approving immediately would resolve a request whose provider can't deliver data")

        await waitUntil { viewModel.pendingCapabilityPickerLayout == nil }
        XCTAssertNil(viewModel.pendingCapabilityPickerLayout,
                     "Once the connect succeeds the captured approval must go out and dismiss the sheet")
    }

    func testConnectUnlinkedProvidersSucceedsThroughOAuth() async {
        let outcome = await ConversationViewModel.connectUnlinkedProviders(
            [ProviderID(rawValue: "composio.googlecalendar")],
            authorizer: StubDeviceAuthorizer(),
            registry: InMemoryCapabilityProviderRegistry(),
            cloudConnectionManager: MockCloudConnectionManager()
        )

        XCTAssertEqual(outcome, .linked)
    }

    func testConnectUnlinkedProvidersInterruptsWhenOAuthCancelled() async {
        let outcome = await ConversationViewModel.connectUnlinkedProviders(
            [ProviderID(rawValue: "composio.googlecalendar")],
            authorizer: StubDeviceAuthorizer(),
            registry: InMemoryCapabilityProviderRegistry(),
            cloudConnectionManager: CancelledCloudConnectionManager()
        )

        XCTAssertEqual(outcome, .interrupted, "A cancelled OAuth must never let the approval proceed, and must not surface an error banner")
    }

    func testConnectUnlinkedProvidersInterruptsForUnknownProvider() async {
        let outcome = await ConversationViewModel.connectUnlinkedProviders(
            [ProviderID(rawValue: "bogus.provider")],
            authorizer: StubDeviceAuthorizer(),
            registry: InMemoryCapabilityProviderRegistry(),
            cloudConnectionManager: MockCloudConnectionManager()
        )

        XCTAssertEqual(outcome, .interrupted, "Providers with no connect path must not let the approval proceed")
    }

    func testConnectUnlinkedProvidersSurfacesErrorWhenConnectFails() async {
        let outcome = await ConversationViewModel.connectUnlinkedProviders(
            [ProviderID(rawValue: "composio.googlecalendar")],
            authorizer: StubDeviceAuthorizer(),
            registry: InMemoryCapabilityProviderRegistry(),
            cloudConnectionManager: FailingCloudConnectionManager()
        )

        guard case .failed = outcome else {
            XCTFail("A genuine connect failure must surface an error so the sheet stops looking inert")
            return
        }
    }

    // MARK: - Helpers

    private func waitUntil(
        timeout: TimeInterval = 5.0,
        _ condition: () -> Bool
    ) async {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition(), Date() < deadline {
            try? await Task.sleep(for: .milliseconds(20))
        }
    }

    private func makeViewModel() -> ConversationViewModel {
        ConversationViewModel(
            conversation: .mock(id: "test-convo"),
            session: MockInboxesService(),
            messagingService: MockMessagingService(),
            applyGlobalDefaultsForNewConversation: false
        )
    }

    private func makeRequest(requestId: String = "req-1") -> CapabilityRequest {
        CapabilityRequest(
            requestId: requestId,
            askerInboxId: "agent-inbox",
            subject: .calendar,
            capability: .read,
            rationale: "To book that meeting",
            preferredProviders: [ProviderID(rawValue: "composio.googlecalendar")]
        )
    }

    private func makeLayout(
        requestId: String,
        variant: CapabilityPickerLayout.Variant = .confirm,
        linked: Bool = true
    ) -> CapabilityPickerLayout {
        CapabilityPickerLayout(
            request: makeRequest(requestId: requestId),
            variant: variant,
            providers: [
                CapabilityPickerLayout.ProviderSummary(
                    id: ProviderID(rawValue: "composio.googlecalendar"),
                    displayName: "Google Calendar",
                    iconName: "calendar",
                    subject: .calendar,
                    linked: linked,
                    supportsCapability: true
                ),
            ],
            defaultSelection: linked ? [ProviderID(rawValue: "composio.googlecalendar")] : []
        )
    }

    private func makePrompt(requestId: String, status: CapabilityConnectPrompt.Status) -> CapabilityConnectPrompt {
        CapabilityConnectPrompt(
            requestId: requestId,
            askerInboxId: "agent-inbox",
            serviceName: "Google Calendar",
            serviceId: "googlecalendar",
            icon: .calendar,
            status: status
        )
    }
}

// MARK: - Stubs

private struct StubDeviceAuthorizer: DeviceConnectionAuthorizer {
    func currentAuthorization(for kind: ConnectionKind) async -> ConnectionAuthorizationStatus { .notDetermined }
    func requestAuthorization(for kind: ConnectionKind) async throws -> ConnectionAuthorizationStatus { .notDetermined }
}

private struct CancelledCloudConnectionManager: CloudConnectionManagerProtocol {
    func connect(serviceId: String) async throws -> CloudConnection { throw OAuthError.cancelled }
    func disconnect(connectionId: String) async throws {}
    func refreshConnections() async throws -> [CloudConnection] { [] }
}

/// Scope resolver with test-controlled results and timing: `setGated(true)`
/// parks subsequent resolutions (each captures the result at call time, so a
/// released call returns what the world looked like when it started);
/// `releaseAll()` resumes them.
private final class StubScopeRepository: CapabilityRequestRepositoryProtocol, @unchecked Sendable {
    // Never emits: an emission (even nil) would asynchronously clear the
    // layout and scope state the test arranged by hand.
    let pendingRequestPublisher: AnyPublisher<CapabilityRequest?, Never> =
        Empty(completeImmediately: false).eraseToAnyPublisher()

    private let lock = NSLock()
    private var result: CapabilityGrantScopeResolution
    private var gated = false
    private var waiters: [CheckedContinuation<Void, Never>] = []
    private var calls = 0

    var callCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return calls
    }

    init(initial: CapabilityGrantScopeResolution) {
        self.result = initial
    }

    var waiterCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return waiters.count
    }

    func setResult(_ new: CapabilityGrantScopeResolution) {
        lock.lock()
        defer { lock.unlock() }
        result = new
    }

    func setGated(_ value: Bool) {
        lock.lock()
        defer { lock.unlock() }
        gated = value
    }

    func releaseAll() {
        lock.lock()
        let toRelease = waiters
        waiters.removeAll()
        lock.unlock()
        for waiter in toRelease {
            waiter.resume()
        }
    }

    private func snapshotResultAndGate() -> (CapabilityGrantScopeResolution, Bool) {
        lock.lock()
        defer { lock.unlock() }
        calls += 1
        return (result, gated)
    }

    private func park(_ continuation: CheckedContinuation<Void, Never>) {
        lock.lock()
        defer { lock.unlock() }
        waiters.append(continuation)
    }

    func resolveGrantScope(
        isAgentDm: Bool,
        askerInboxId: String,
        liveMarkerOrigin: @escaping @Sendable () async -> String?
    ) async -> CapabilityGrantScopeResolution {
        let (snapshot, shouldWait) = snapshotResultAndGate()
        if shouldWait {
            await withCheckedContinuation { continuation in
                park(continuation)
            }
        }
        return snapshot
    }
}

private struct FailingCloudConnectionManager: CloudConnectionManagerProtocol {
    enum StubError: Error { case connectFailed }
    func connect(serviceId: String) async throws -> CloudConnection { throw StubError.connectFailed }
    func disconnect(connectionId: String) async throws {}
    func refreshConnections() async throws -> [CloudConnection] { [] }
}
