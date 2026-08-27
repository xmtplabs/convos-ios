@testable import Convos
import ConvosComposer
import ConvosConnections
import ConvosCore
import Testing
import UIKit

@MainActor
struct DocFeedbackFlowTests {
    @Test("null-state home waits for the Worker contribution line")
    func nullStateHomeWaitsForControlLine() throws {
        let suiteName = "DocContributionLineTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let viewModel = DocExperienceViewModel(
            session: MockInboxesService(),
            coreActions: NoOpCoreActions(),
            defaults: defaults
        )

        #expect(viewModel.docs.isEmpty)
        #expect(viewModel.contributionLine.isEmpty)
    }

    @Test("control contribution line overrides editorial compatibility state")
    func controlContributionLineIsAuthoritative() throws {
        let suiteName = "DocControlContributionLineTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let viewModel = DocExperienceViewModel(
            session: MockInboxesService(),
            coreActions: NoOpCoreActions(),
            defaults: defaults
        )
        let agent = ConversationMember(
            profile: .mock(inboxId: "doc-agent", name: "Doc"),
            role: .member,
            isCurrentUser: false,
            isAgent: true
        )
        let text = #"⟦doc⟧{"v":1,"t":"control","instanceId":"F47AC10B-58CC-4372-A567-0E02B2C3D479","epoch":"7D9E6679-7425-40DE-944B-E07FC1F90AE7","seq":2,"at":1787720400,"key":"line","kind":"line","line":{"status":"available","lineNumber":"+14155550100"}}"#
        let message = AnyMessage.message(
            Message(
                id: "control-line",
                sender: agent,
                source: .incoming,
                status: .published,
                content: .text(text),
                date: Date(timeIntervalSince1970: 2),
                reactions: []
            ),
            .existing
        )

        viewModel.ingestAggregatedMessages([message], agentInboxId: agent.profile.inboxId)

        #expect(viewModel.contributionLine == "+14155550100")
        #expect(docDisplayPhoneNumber(viewModel.contributionLine) == "+1 (415) 555-0100")
    }

    @Test("Doc number copy excludes the share message")
    func docNumberCopyExcludesShareMessage() {
        let number = "+14155550100"
        UIPasteboard.general.string = "Doc at \(number)"

        DocCopyNumberActivity.copy(number: number)

        #expect(UIPasteboard.general.string == number)
    }

    @Test("authorized Doc storage resumes after a registering launch")
    func authorizedStorageRestoresRelaunchWithoutReprovisioning() async throws {
        let suiteName = "DocAuthorizedStorageTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let inboxId = "authorized-inbox"
        let client = MockXMTPClientProvider(inboxId: inboxId)
        let stateManager = MockSessionStateManager(
            initialState: .registering,
            mockClient: client
        )
        let session = MockInboxesService(
            mockMessagingService: MockMessagingService(sessionStateManager: stateManager)
        )
        defaults.set(
            true,
            forKey: DocExperienceViewModel.storageKey(
                "welcome",
                accountIdentifier: "registering"
            )
        )
        defaults.set(
            "origin-conversation",
            forKey: DocExperienceViewModel.storageKey(
                "originConversationId",
                accountIdentifier: "registering"
            )
        )

        let firstLaunch = DocExperienceViewModel(
            session: session,
            coreActions: NoOpCoreActions(),
            defaults: defaults
        )
        firstLaunch.adoptAuthorizedStorage(inboxId: inboxId)
        let readyResult = try await stateManager.waitForInboxReadyResult()
        stateManager.setState(.ready(readyResult))

        let relaunched = DocExperienceViewModel(
            session: session,
            coreActions: NoOpCoreActions(),
            defaults: defaults
        )

        #expect(relaunched.hasCompletedWelcome)
        #expect(DocExperienceViewModel.storedOriginConversationId(
            session: session,
            defaults: defaults
        ) == "origin-conversation")
        #expect(defaults.object(forKey: DocExperienceViewModel.storageKey(
            "welcome",
            accountIdentifier: "registering"
        )) == nil)
    }

    @Test("Doc composer fork includes the History action")
    func composerForkIncludesHistory() {
        #expect(DocComposerBar.renderedActionKinds == [.history, .photos, .send])
    }

    @Test("compact relative time clamps extreme finite dates")
    func compactRelativeTimeClampsExtremeFiniteDates() {
        let now = Date(timeIntervalSince1970: 1)
        let distantPast = Date(timeIntervalSince1970: -Double.greatestFiniteMagnitude)

        #expect(docCompactRelativeTime(from: distantPast, relativeTo: now).hasSuffix("d"))
    }

    @Test("lane sentinel is emitted only once per document")
    func laneSentinelEmitsOncePerDoc() {
        var registry = DocLaneRegistry()
        registry.register(conversationId: "doc-lane", for: "tahoe")

        #expect(registry.takeAnnouncement(for: "tahoe") == #"⟦lane⟧{"docId":"tahoe"}"#)
        #expect(registry.takeAnnouncement(for: "tahoe") == nil)
        #expect(registry.conversationId(for: "tahoe") == "doc-lane")
    }

    @Test("screenshot picker has no artificial selection cap")
    func screenshotPickerIsUnlimited() {
        #expect(DocScreenshotSelectionPolicy.maximumSelectionCount == nil)
    }

    @Test("composer retains screenshot selections beyond the transcript message cap")
    func composerRetainsUnlimitedScreenshots() {
        let viewModel = DocExperienceViewModel(
            session: MockInboxesService(),
            coreActions: NoOpCoreActions()
        )

        for _ in 0..<(maxPendingMediaAttachments + 5) {
            viewModel.addPendingPhoto(UIImage(), in: .home)
        }

        #expect(viewModel.pendingPhotos(in: .home).count == maxPendingMediaAttachments + 5)
    }

    @Test("composer waits for every selected screenshot to finish loading")
    func composerWaitsForEntirePhotoSelection() {
        var gate = DocPhotoLoadGate()
        gate.begin(count: 3)

        #expect(!gate.canSend(isReady: true, isSending: false, hasPayload: true))
        gate.finishOne()
        #expect(gate.pendingCount == 2)
        #expect(!gate.canSend(isReady: true, isSending: false, hasPayload: true))
        gate.finishOne()
        gate.finishOne()
        #expect(gate.canSend(isReady: true, isSending: false, hasPayload: true))
    }

    @Test("Google connect chains V2 entitlement into conversation extension")
    func googleConnectChainsV2EntitlementAndExtension() async throws {
        var calls: [String] = []

        try await DocGoogleConnectionChain.connectAndExtend(
            entitlementIsActive: false,
            bundleIds: ["documents.read", "documents.write"],
            beginEntitlement: {
                calls.append("begin")
                return AbilityEntitlementInitiation(
                    status: .pendingAuth,
                    redirectUrl: "https://example.com/connect"
                )
            },
            authorize: { redirectUrl in
                calls.append("authorize:\(redirectUrl)")
            },
            completeEntitlement: {
                calls.append("complete")
            },
            extend: { bundleIds in
                calls.append("extend:\(bundleIds.joined(separator: ","))")
            }
        )

        #expect(calls == [
            "begin",
            "authorize:https://example.com/connect",
            "complete",
            "extend:documents.read,documents.write",
        ])
    }

    @Test("Google connect reuses an active V2 entitlement before extension")
    func googleConnectReusesActiveV2Entitlement() async throws {
        var calls: [String] = []

        try await DocGoogleConnectionChain.connectAndExtend(
            entitlementIsActive: true,
            bundleIds: ["documents.write"],
            beginEntitlement: {
                calls.append("begin")
                return AbilityEntitlementInitiation(status: .active)
            },
            authorize: { _ in
                calls.append("authorize")
            },
            completeEntitlement: {
                calls.append("complete")
            },
            extend: { bundleIds in
                calls.append("extend:\(bundleIds.joined(separator: ","))")
            }
        )

        #expect(calls == ["extend:documents.write"])
    }

    @Test("Google connect sends a fresh granted event to every agent on each attempt")
    func googleConnectSendsGrantedEventsPerAgentAndAttempt() async throws {
        let writer = RecordingDocConnectionEventWriter()
        let target = DocGoogleConnectTarget(
            conversationId: "doc-dm",
            agentInboxIds: ["doc-agent-1", "doc-agent-2"]
        )

        try await DocGoogleConnectionChain.sendGrantedEvents(target: target, eventWriter: writer)
        try await DocGoogleConnectionChain.sendGrantedEvents(target: target, eventWriter: writer)

        let expectedAttempt = target.agentInboxIds.map {
            RecordingDocConnectionEventWriter.Grant(
                providerId: "composio.googledocs",
                capability: nil,
                grantedToInboxId: $0,
                conversationId: "doc-dm"
            )
        }
        #expect(await writer.grants() == expectedAttempt + expectedAttempt)
    }
}

private actor RecordingDocConnectionEventWriter: ConnectionEventWriterProtocol {
    struct Grant: Equatable, Sendable {
        let providerId: String
        let capability: ConnectionCapability?
        let grantedToInboxId: String?
        let conversationId: String
    }

    private var recordedGrants: [Grant] = []

    func grants() -> [Grant] {
        recordedGrants
    }

    func sendGranted(
        providerId: String,
        capability: ConnectionCapability?,
        grantedToInboxId: String?,
        in conversationId: String
    ) async throws {
        recordedGrants.append(Grant(
            providerId: providerId,
            capability: capability,
            grantedToInboxId: grantedToInboxId,
            conversationId: conversationId
        ))
    }

    func sendRevoked(
        providerId: String,
        capability: ConnectionCapability?,
        grantedToInboxId: String?,
        in conversationId: String
    ) async throws {}
}
