import Combine
@testable import Convos
import ConvosConnections
import ConvosCore
import XCTest

/// Approval-confirmation coverage: an `.approved` capability result is
/// contingent on a confirmed backend grant POST. A failed POST leaves the
/// approval unconfirmed (nothing may broadcast, the sheet surfaces a
/// retryable error, the pill stays pending), a previously unconfirmed grant
/// retries the push on the next Done tap, and a grant already confirmed with
/// the same scope is skipped.
@MainActor
final class ConversationViewModelApproveConfirmationTests: XCTestCase {
    private let googleCalendar = ProviderID(rawValue: "composio.googlecalendar")

    // MARK: - persistApprovedCloudCapabilities

    func testGrantPostFailureLeavesApprovalUnconfirmed() async {
        let grantWriter = ConfigurableGrantWriter()
        grantWriter.confirmingGrantError = ConfigurableGrantWriter.Failure()
        let eventWriter = SpyEventWriter()

        let confirmed = await ConversationViewModel.persistApprovedCloudCapabilities(
            providerIds: [googleCalendar],
            newlyApprovedProviderIds: [googleCalendar],
            bundleSelection: ["googlecalendar": ["calendar.events"]],
            capability: .read,
            conversationId: "convo-1",
            grantedToInboxId: "agent-inbox",
            grantWriter: grantWriter,
            eventWriter: eventWriter,
            repository: StubConnectionsRepository(
                stubbedConnections: [makeConnection()],
                stubbedGrants: []
            )
        )

        XCTAssertFalse(confirmed,
                       "A failed grant POST must leave the approval unconfirmed so no .approved result broadcasts")
        XCTAssertEqual(grantWriter.confirmingGrants.count, 1,
                       "The confirming push was attempted exactly once")
        XCTAssertTrue(eventWriter.grantedProviderIds.isEmpty,
                      "No granted transcript line may announce a grant the backend never confirmed")
    }

    func testConfirmedGrantPostApprovesAndEmitsGrantedEvent() async {
        let grantWriter = ConfigurableGrantWriter()
        let eventWriter = SpyEventWriter()

        let confirmed = await ConversationViewModel.persistApprovedCloudCapabilities(
            providerIds: [googleCalendar],
            newlyApprovedProviderIds: [googleCalendar],
            bundleSelection: ["googlecalendar": ["calendar.events"]],
            capability: .read,
            conversationId: "convo-1",
            grantedToInboxId: "agent-inbox",
            grantWriter: grantWriter,
            eventWriter: eventWriter,
            repository: StubConnectionsRepository(
                stubbedConnections: [makeConnection()],
                stubbedGrants: []
            )
        )

        XCTAssertTrue(confirmed)
        XCTAssertEqual(grantWriter.confirmingGrants, [
            ConfigurableGrantWriter.Grant(
                connectionId: "conn-1",
                conversationId: "convo-1",
                grantedToInboxId: "agent-inbox",
                bundleIds: ["calendar.events"]
            ),
        ])
        XCTAssertEqual(eventWriter.grantedProviderIds, ["composio.googlecalendar"])
    }

    func testExistingConfirmedGrantWithSameScopeSkipsRepush() async {
        let grantWriter = ConfigurableGrantWriter()
        let eventWriter = SpyEventWriter()

        let confirmed = await ConversationViewModel.persistApprovedCloudCapabilities(
            providerIds: [googleCalendar],
            newlyApprovedProviderIds: [googleCalendar],
            bundleSelection: ["googlecalendar": ["calendar.events"]],
            capability: .read,
            conversationId: "convo-1",
            grantedToInboxId: "agent-inbox",
            grantWriter: grantWriter,
            eventWriter: eventWriter,
            repository: StubConnectionsRepository(
                stubbedConnections: [makeConnection()],
                stubbedGrants: [
                    makeGrant(backendGrantId: "backend-1", bundleIds: ["calendar.events"]),
                ]
            )
        )

        XCTAssertTrue(confirmed, "A grant the backend already confirmed backs the approval as-is")
        XCTAssertTrue(grantWriter.confirmingGrants.isEmpty,
                      "Same scope + confirmed backend id: no re-push needed")
        XCTAssertEqual(eventWriter.grantedProviderIds, ["composio.googlecalendar"],
                       "The granted line follows the resolver diff, not the grant write")
    }

    func testExistingUnconfirmedGrantRetriesBackendPush() async {
        let grantWriter = ConfigurableGrantWriter()
        let eventWriter = SpyEventWriter()

        let confirmed = await ConversationViewModel.persistApprovedCloudCapabilities(
            providerIds: [googleCalendar],
            newlyApprovedProviderIds: [],
            bundleSelection: ["googlecalendar": ["calendar.events"]],
            capability: .read,
            conversationId: "convo-1",
            grantedToInboxId: "agent-inbox",
            grantWriter: grantWriter,
            eventWriter: eventWriter,
            repository: StubConnectionsRepository(
                stubbedConnections: [makeConnection()],
                stubbedGrants: [
                    makeGrant(backendGrantId: nil, bundleIds: ["calendar.events"]),
                ]
            )
        )

        XCTAssertTrue(confirmed)
        XCTAssertEqual(grantWriter.confirmingGrants.count, 1,
                       "A local grant whose earlier POST never confirmed re-runs the confirming push on retry")
    }

    func testMissingActiveConnectionLeavesApprovalUnconfirmed() async {
        let grantWriter = ConfigurableGrantWriter()
        let eventWriter = SpyEventWriter()

        let confirmed = await ConversationViewModel.persistApprovedCloudCapabilities(
            providerIds: [googleCalendar],
            newlyApprovedProviderIds: [googleCalendar],
            bundleSelection: ["googlecalendar": ["calendar.events"]],
            capability: .read,
            conversationId: "convo-1",
            grantedToInboxId: "agent-inbox",
            grantWriter: grantWriter,
            eventWriter: eventWriter,
            repository: StubConnectionsRepository(stubbedConnections: [], stubbedGrants: [])
        )

        XCTAssertFalse(confirmed,
                       "Without an active connection no server grant can back the approval")
        XCTAssertTrue(grantWriter.confirmingGrants.isEmpty)
        XCTAssertTrue(eventWriter.grantedProviderIds.isEmpty)
    }

    // MARK: - Approval pipeline keeps the request pending on failure

    func testFailedApprovalKeepsSheetUpAndRequestPending() async throws {
        // MockInboxesService's connection repository holds no active
        // connections, so the approval pipeline cannot confirm a grant --
        // the exact state a failed grant POST leaves behind.
        let viewModel = ConversationViewModel(
            conversation: .mock(id: "test-convo"),
            session: MockInboxesService(),
            messagingService: MockMessagingService(),
            applyGlobalDefaultsForNewConversation: false
        )
        // Let the mock request repository's single nil emission land before
        // seeding the layout, so the fixture's empty publisher can't clear
        // the seeded layout mid-test. In production the publisher keeps
        // emitting the still-pending request instead.
        try await Task.sleep(nanoseconds: 100_000_000)
        viewModel.pendingCapabilityPickerLayout = makeLayout(requestId: "req-1")
        viewModel.onTapCapabilityConnectPrompt(makePrompt(requestId: "req-1"))
        XCTAssertTrue(viewModel.presentingCapabilityApproval)

        viewModel.onCapabilityApprove(
            providerIds: [googleCalendar],
            bundleSelection: ["googlecalendar": ["calendar.events"]]
        )

        try await waitUntil("approval failure surfaces in the sheet") {
            viewModel.capabilityApprovalErrorMessage != nil
        }
        XCTAssertNotNil(viewModel.pendingCapabilityPickerLayout,
                        "A failed approval must not consume the prompt card -- the request stays pending")
        XCTAssertTrue(viewModel.presentingCapabilityApproval,
                      "The sheet stays up so the user can retry")
        XCTAssertFalse(viewModel.capabilityApprovalInFlight,
                       "The in-flight guard resets so the retry tap can run")
        XCTAssertFalse(viewModel.showsCapabilityApprovedToast,
                       "No approved toast for an approval that never broadcast")
    }

    // MARK: - Helpers

    private func waitUntil(
        _ description: String,
        timeout: TimeInterval = 5.0,
        condition: @MainActor () -> Bool
    ) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return }
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        XCTFail("Timed out waiting for: \(description)")
    }

    private func makeConnection(
        id: String = "conn-1",
        serviceId: String = "googlecalendar"
    ) -> CloudConnection {
        CloudConnection(
            id: id,
            serviceId: serviceId,
            serviceName: "Google Calendar",
            provider: .composio,
            composioEntityId: "entity-1",
            composioConnectionId: "ca-1",
            status: .active,
            connectedAt: Date(timeIntervalSince1970: 0)
        )
    }

    private func makeGrant(
        backendGrantId: String?,
        bundleIds: [String]
    ) -> CloudConnectionGrant {
        CloudConnectionGrant(
            connectionId: "conn-1",
            conversationId: "convo-1",
            serviceId: "googlecalendar",
            grantedToInboxId: "agent-inbox",
            grantedAt: Date(timeIntervalSince1970: 0),
            bundleIds: bundleIds,
            backendGrantId: backendGrantId
        )
    }

    private func makeLayout(requestId: String) -> CapabilityPickerLayout {
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
                    ],
                    grantedBundleIds: nil
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

private final class ConfigurableGrantWriter: CloudConnectionGrantWriterProtocol, @unchecked Sendable {
    struct Grant: Equatable {
        let connectionId: String
        let conversationId: String
        let grantedToInboxId: String
        let bundleIds: [String]?
    }

    struct Failure: Error {}

    private let lock = NSLock()
    private var recordedConfirmingGrants: [Grant] = []
    private var confirmingError: Error?

    var confirmingGrants: [Grant] { lock.withLock { recordedConfirmingGrants } }
    var confirmingGrantError: Error? {
        get { lock.withLock { confirmingError } }
        set { lock.withLock { confirmingError = newValue } }
    }

    func grantConnection(
        _ connectionId: String,
        to conversationId: String,
        grantedToInboxId: String,
        bundleIds: [String]?
    ) async throws {}

    func grantConnectionConfirmingBackend(
        _ connectionId: String,
        to conversationId: String,
        grantedToInboxId: String,
        bundleIds: [String]?
    ) async throws {
        lock.withLock {
            recordedConfirmingGrants.append(Grant(
                connectionId: connectionId,
                conversationId: conversationId,
                grantedToInboxId: grantedToInboxId,
                bundleIds: bundleIds
            ))
        }
        if let error = confirmingGrantError {
            throw error
        }
    }

    func revokeGrant(
        connectionId: String,
        from conversationId: String,
        grantedToInboxId: String
    ) async throws {}
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

private struct StubConnectionsRepository: CloudConnectionRepositoryProtocol {
    let stubbedConnections: [CloudConnection]
    let stubbedGrants: [CloudConnectionGrant]

    func connections() async throws -> [CloudConnection] {
        stubbedConnections
    }

    func connectionsPublisher() -> AnyPublisher<[CloudConnection], Never> {
        Just(stubbedConnections).eraseToAnyPublisher()
    }

    func grants(for conversationId: String) async throws -> [CloudConnectionGrant] {
        stubbedGrants.filter { $0.conversationId == conversationId }
    }

    func grantsPublisher(for conversationId: String) -> AnyPublisher<[CloudConnectionGrant], Never> {
        Just(stubbedGrants).eraseToAnyPublisher()
    }
}
