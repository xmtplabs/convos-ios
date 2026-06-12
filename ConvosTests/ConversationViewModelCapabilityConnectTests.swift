@testable import Convos
import ConvosCore
import XCTest

/// Covers the transcript connect pill's view-model seam: the tap handler
/// gating, the auto-dismiss tie between the pending layout and the approval
/// sheet, and the shared layout computation that must always resolve the
/// services catalog (the OAuth-error recompute path used to omit it, dropping
/// bundle rows so an approve silently escalated to full-service consent).
@MainActor
final class ConversationViewModelCapabilityConnectTests: XCTestCase {
    func testComputeCapabilityPickerLayoutPopulatesBundleRows() async {
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

        let layout = await ConversationViewModel.computeCapabilityPickerLayout(
            request: makeRequest(),
            registry: registry,
            resolver: resolver,
            handler: CapabilityRequestHandler(),
            servicesStore: servicesStore,
            conversationId: "test-convo"
        )

        XCTAssertEqual(layout.serviceBundles.count, 1,
                       "Catalog-backed services must surface their bundle rows")
        XCTAssertEqual(layout.serviceBundles.first?.serviceId, "googlecalendar")
        XCTAssertEqual(layout.serviceBundles.first?.rows.map(\.id), ["calendar.events"])
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

    // MARK: - Helpers

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

    private func makeLayout(requestId: String) -> CapabilityPickerLayout {
        CapabilityPickerLayout(
            request: makeRequest(requestId: requestId),
            variant: .confirm,
            providers: [
                CapabilityPickerLayout.ProviderSummary(
                    id: ProviderID(rawValue: "composio.googlecalendar"),
                    displayName: "Google Calendar",
                    iconName: "calendar",
                    subject: .calendar,
                    linked: true,
                    supportsCapability: true
                ),
            ],
            defaultSelection: [ProviderID(rawValue: "composio.googlecalendar")]
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
