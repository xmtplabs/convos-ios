import Combine
@testable import Convos
import ConvosConnections
import ConvosCore
import XCTest

/// Done-as-revoke coverage: the per-service split of one Done tap (checked
/// services approve, all-off services revoke-or-no-op, an empty bundle set
/// never reaches the grant writer), the natural-key revoke seam, and the
/// approval sheet's toggle seeding from an existing grant.
@MainActor
final class ConversationViewModelDoneRevokeTests: XCTestCase {
    private let googleCalendar = ProviderID(rawValue: "composio.googlecalendar")
    private let gmail = ProviderID(rawValue: "composio.gmail")

    // MARK: - splitCapabilityApproval

    func testSplitKeepsCheckedSelectionIntact() {
        let split = ConversationViewModel.splitCapabilityApproval(
            providerIds: [googleCalendar],
            bundleSelection: ["googlecalendar": ["calendar.events"]]
        )

        XCTAssertEqual(split.approvedProviderIds, [googleCalendar])
        XCTAssertEqual(split.approvedBundleSelection, ["googlecalendar": ["calendar.events"]])
        XCTAssertTrue(split.uncheckedServiceIds.isEmpty)
    }

    func testSplitDropsAllOffServiceFromApproval() {
        let split = ConversationViewModel.splitCapabilityApproval(
            providerIds: [googleCalendar],
            bundleSelection: ["googlecalendar": []]
        )

        XCTAssertTrue(split.approvedProviderIds.isEmpty,
                      "An all-off service must not be approved on the agent's behalf")
        XCTAssertEqual(split.uncheckedServiceIds, ["googlecalendar"])
        XCTAssertFalse(split.approvedBundleSelection.values.contains(where: \.isEmpty),
                       "The empty-bundle invariant: [] must never travel toward the grant writer")
        XCTAssertTrue(split.approvedBundleSelection.isEmpty)
    }

    func testSplitMixedMultiServiceAppliesPerService() {
        let split = ConversationViewModel.splitCapabilityApproval(
            providerIds: [googleCalendar, gmail],
            bundleSelection: [
                "googlecalendar": [],
                "gmail": ["mail.read"],
            ]
        )

        XCTAssertEqual(split.approvedProviderIds, [gmail])
        XCTAssertEqual(split.approvedBundleSelection, ["gmail": ["mail.read"]])
        XCTAssertEqual(split.uncheckedServiceIds, ["googlecalendar"])
    }

    func testSplitLeavesProvidersWithoutBundleEntriesAlone() {
        // A service without catalog rows has no toggles — it must stay in the
        // approved set (full-service consent path, nil bundleIds downstream).
        let split = ConversationViewModel.splitCapabilityApproval(
            providerIds: [googleCalendar],
            bundleSelection: [:]
        )

        XCTAssertEqual(split.approvedProviderIds, [googleCalendar])
        XCTAssertTrue(split.uncheckedServiceIds.isEmpty)
    }

    // MARK: - revokeUncheckedCloudGrants

    func testUncheckedServiceWithExistingGrantRevokesByNaturalKey() async {
        let grantWriter = SpyGrantWriter()
        let eventWriter = SpyEventWriter()
        let registry = InMemoryCapabilityProviderRegistry()
        let resolver = InMemoryCapabilityResolver(registry: registry)
        try? await resolver.setResolution(
            [googleCalendar],
            subject: .calendar,
            capability: .read,
            conversationId: "convo-1",
            grantedToInboxId: "agent-inbox"
        )

        let revoked = await ConversationViewModel.revokeUncheckedCloudGrants(
            serviceIds: ["googlecalendar"],
            grantedToInboxId: "agent-inbox",
            conversationId: "convo-1",
            grantWriter: grantWriter,
            eventWriter: eventWriter,
            resolver: resolver,
            repository: StubGrantsRepository(grants: [
                makeGrant(connectionId: "conn-1", grantedToInboxId: "agent-inbox"),
            ])
        )

        XCTAssertEqual(revoked, ["googlecalendar"])
        XCTAssertEqual(grantWriter.revokes, [
            SpyGrantWriter.Revoke(
                connectionId: "conn-1",
                conversationId: "convo-1",
                grantedToInboxId: "agent-inbox"
            ),
        ], "The revoke must target the natural key: connection + conversation + agent")
        XCTAssertTrue(grantWriter.grants.isEmpty, "A revoke tap must never create a grant")
        XCTAssertEqual(eventWriter.revokedProviderIds, ["composio.googlecalendar"],
                       "The transcript reflects the revocation via a connection_event revoked line")
        XCTAssertTrue(eventWriter.grantedProviderIds.isEmpty)
        let resolution = await resolver.resolution(
            subject: .calendar,
            capability: .read,
            conversationId: "convo-1",
            grantedToInboxId: "agent-inbox"
        )
        XCTAssertTrue(resolution.isEmpty,
                      "Resolver cleanup re-arms the granted-event idempotency gate for a later re-approval")
    }

    func testUncheckedServiceWithoutGrantIsNoOp() async {
        let grantWriter = SpyGrantWriter()
        let eventWriter = SpyEventWriter()
        let registry = InMemoryCapabilityProviderRegistry()

        let revoked = await ConversationViewModel.revokeUncheckedCloudGrants(
            serviceIds: ["googlecalendar"],
            grantedToInboxId: "agent-inbox",
            conversationId: "convo-1",
            grantWriter: grantWriter,
            eventWriter: eventWriter,
            resolver: InMemoryCapabilityResolver(registry: registry),
            repository: StubGrantsRepository(grants: [])
        )

        XCTAssertTrue(revoked.isEmpty)
        XCTAssertTrue(grantWriter.revokes.isEmpty, "No grant exists — nothing to revoke")
        XCTAssertTrue(grantWriter.grants.isEmpty, "A decline-style no-op must never create a grant")
        XCTAssertTrue(eventWriter.revokedProviderIds.isEmpty)
        XCTAssertTrue(eventWriter.grantedProviderIds.isEmpty)
    }

    func testUncheckedServiceScopedToAskingAgent() async {
        let grantWriter = SpyGrantWriter()
        let eventWriter = SpyEventWriter()
        let registry = InMemoryCapabilityProviderRegistry()

        let revoked = await ConversationViewModel.revokeUncheckedCloudGrants(
            serviceIds: ["googlecalendar"],
            grantedToInboxId: "agent-inbox",
            conversationId: "convo-1",
            grantWriter: grantWriter,
            eventWriter: eventWriter,
            resolver: InMemoryCapabilityResolver(registry: registry),
            repository: StubGrantsRepository(grants: [
                makeGrant(connectionId: "conn-1", grantedToInboxId: "other-agent"),
            ])
        )

        XCTAssertTrue(revoked.isEmpty)
        XCTAssertTrue(grantWriter.revokes.isEmpty,
                      "Another agent's grant must survive this agent's unchecked toggle")
    }

    // MARK: - onCapabilityApprove with everything unchecked

    func testApproveAllTogglesOffDismissesSheetAndKeepsRequestPending() {
        let viewModel = ConversationViewModel(
            conversation: .mock(id: "test-convo"),
            session: MockInboxesService(),
            messagingService: MockMessagingService(),
            applyGlobalDefaultsForNewConversation: false
        )
        viewModel.pendingCapabilityPickerLayout = makeLayout(requestId: "req-1")
        viewModel.onTapCapabilityConnectPrompt(makePrompt(requestId: "req-1"))
        XCTAssertTrue(viewModel.presentingCapabilityApproval)

        viewModel.onCapabilityApprove(
            providerIds: [googleCalendar],
            bundleSelection: ["googlecalendar": []]
        )

        XCTAssertFalse(viewModel.presentingCapabilityApproval,
                       "All-off + Done dismisses the sheet")
        XCTAssertNotNil(viewModel.pendingCapabilityPickerLayout,
                        "No .approved result may go out — the request stays pending (no-Deny posture) and the pill stays tappable")
    }

    // MARK: - Sheet toggle seeding

    func testSheetSeedsAllOnWithoutExistingGrant() {
        let layout = makeLayout(requestId: "req-1", grantedBundleIds: nil)

        let seed = CapabilityApprovalSheetView.seedBundleSelection(for: layout)

        XCTAssertEqual(seed, ["googlecalendar": ["calendar.events", "calendar.events.read"]],
                       "Pill-tap intent: no grant seeds every toggle ON")
    }

    func testSheetSeedsGrantedStateWithExistingGrant() {
        let layout = makeLayout(requestId: "req-1", grantedBundleIds: ["calendar.events.read"])

        let seed = CapabilityApprovalSheetView.seedBundleSelection(for: layout)

        XCTAssertEqual(seed, ["googlecalendar": ["calendar.events.read"]],
                       "An existing grant seeds the granted rows ON and the rest OFF")
    }

    func testSheetSeedDropsGrantedIdsTheCatalogNoLongerKnows() {
        let layout = makeLayout(
            requestId: "req-1",
            grantedBundleIds: ["calendar.events", "calendar.gone"]
        )

        let seed = CapabilityApprovalSheetView.seedBundleSelection(for: layout)

        XCTAssertEqual(seed, ["googlecalendar": ["calendar.events"]],
                       "Stale granted ids must not produce toggles the catalog can't render")
    }

    // MARK: - Helpers

    private func makeGrant(connectionId: String, grantedToInboxId: String) -> CloudConnectionGrant {
        CloudConnectionGrant(
            connectionId: connectionId,
            conversationId: "convo-1",
            serviceId: "googlecalendar",
            grantedToInboxId: grantedToInboxId,
            grantedAt: Date(timeIntervalSince1970: 0),
            bundleIds: ["calendar.events"]
        )
    }

    private func makeLayout(
        requestId: String,
        grantedBundleIds: Set<String>? = nil
    ) -> CapabilityPickerLayout {
        let request = CapabilityRequest(
            requestId: requestId,
            askerInboxId: "agent-inbox",
            subject: .calendar,
            capability: .read,
            rationale: "To book that meeting"
        )
        return CapabilityPickerLayout(
            request: request,
            variant: .confirm,
            providers: [
                CapabilityPickerLayout.ProviderSummary(
                    id: googleCalendar,
                    displayName: "Google Calendar",
                    iconName: "calendar",
                    subject: .calendar,
                    linked: true,
                    supportsCapability: true
                ),
            ],
            defaultSelection: [googleCalendar],
            serviceBundles: [
                CapabilityPickerLayout.ServiceBundles(
                    providerId: googleCalendar,
                    serviceId: "googlecalendar",
                    serviceVersion: 5,
                    rows: [
                        .init(
                            id: "calendar.events",
                            title: "Events",
                            description: "View and edit events on all calendars",
                            defaultEnabled: false
                        ),
                        .init(
                            id: "calendar.events.read",
                            title: "View events",
                            description: "View events on all calendars",
                            defaultEnabled: true
                        ),
                    ],
                    grantedBundleIds: grantedBundleIds
                ),
            ]
        )
    }

    private func makePrompt(requestId: String) -> CapabilityConnectPrompt {
        CapabilityConnectPrompt(
            requestId: requestId,
            askerInboxId: "agent-inbox",
            serviceName: "Google Calendar",
            serviceId: "googlecalendar",
            icon: .calendar,
            status: .pending
        )
    }
}

// MARK: - Spies

private final class SpyGrantWriter: CloudConnectionGrantWriterProtocol, @unchecked Sendable {
    struct Grant: Equatable {
        let connectionId: String
        let conversationId: String
        let grantedToInboxId: String
        let bundleIds: [String]?
    }

    struct Revoke: Equatable {
        let connectionId: String
        let conversationId: String
        let grantedToInboxId: String
    }

    private let lock = NSLock()
    private var recordedGrants: [Grant] = []
    private var recordedRevokes: [Revoke] = []

    var grants: [Grant] { lock.withLock { recordedGrants } }
    var revokes: [Revoke] { lock.withLock { recordedRevokes } }

    func grantConnection(
        _ connectionId: String,
        to conversationId: String,
        grantedToInboxId: String,
        bundleIds: [String]?
    ) async throws {
        lock.withLock {
            recordedGrants.append(Grant(
                connectionId: connectionId,
                conversationId: conversationId,
                grantedToInboxId: grantedToInboxId,
                bundleIds: bundleIds
            ))
        }
    }

    func revokeGrant(
        connectionId: String,
        from conversationId: String,
        grantedToInboxId: String
    ) async throws {
        lock.withLock {
            recordedRevokes.append(Revoke(
                connectionId: connectionId,
                conversationId: conversationId,
                grantedToInboxId: grantedToInboxId
            ))
        }
    }
}

private final class SpyEventWriter: ConnectionEventWriterProtocol, @unchecked Sendable {
    private let lock = NSLock()
    private var granted: [String] = []
    private var revoked: [String] = []

    var grantedProviderIds: [String] { lock.withLock { granted } }
    var revokedProviderIds: [String] { lock.withLock { revoked } }

    func sendGranted(
        providerId: String,
        capability: ConnectionCapability?,
        grantedToInboxId: String?,
        in conversationId: String
    ) async throws {
        lock.withLock { granted.append(providerId) }
    }

    func sendRevoked(
        providerId: String,
        capability: ConnectionCapability?,
        grantedToInboxId: String?,
        in conversationId: String
    ) async throws {
        lock.withLock { revoked.append(providerId) }
    }
}

private struct StubGrantsRepository: CloudConnectionRepositoryProtocol {
    let grants: [CloudConnectionGrant]

    func connections() async throws -> [CloudConnection] { [] }
    func connectionsPublisher() -> AnyPublisher<[CloudConnection], Never> {
        Just([]).eraseToAnyPublisher()
    }
    func grants(for conversationId: String) async throws -> [CloudConnectionGrant] {
        grants.filter { $0.conversationId == conversationId }
    }
    func grantsPublisher(for conversationId: String) -> AnyPublisher<[CloudConnectionGrant], Never> {
        Just(grants).eraseToAnyPublisher()
    }
}
