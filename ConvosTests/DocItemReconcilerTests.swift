@testable import Convos
import ConvosCore
import Foundation
import Testing

@Suite(.serialized)
struct DocItemReconcilerTests {
    @Test func compatibilityDetectorIgnoresSetupProseUntilAgentRepliesToSourceMaterial() {
        var detector = DocAgentCompatibilityDetector()

        detector.observe(
            text: "An older group message.",
            sender: .currentUser,
            position: position(0)
        )
        detector.observe(
            text: "Google Docs access is approved.",
            sender: .agent,
            position: position(1)
        )
        #expect(!detector.shouldWarn)

        detector.observe(
            text: "Plan a team offsite in October.",
            sender: .currentUser,
            position: position(2)
        )
        #expect(!detector.shouldWarn)

        detector.observe(
            text: "I can help plan that.",
            sender: .agent,
            position: position(3)
        )
        #expect(detector.shouldWarn)
    }

    @Test func compatibilityDetectorDoesNotTreatAnswersAsSourceMaterial() {
        var detector = DocAgentCompatibilityDetector()

        detector.observe(
            text: #"⟦ans⟧{"id":"question","choice":"Dec 14"}"#,
            sender: .currentUser,
            position: position(1)
        )
        detector.observe(
            text: "A normal assistant reply",
            sender: .agent,
            position: position(2)
        )

        #expect(!detector.shouldWarn)
    }

    @Test func compatibilityDetectorSentinelDisarmsWrongAgentWarning() {
        var detector = DocAgentCompatibilityDetector()

        detector.observe(text: "Hello, I'm your assistant.", sender: .agent, position: position(0))
        detector.observe(text: "Draft a launch plan.", sender: .currentUser, position: position(1))
        detector.observe(text: "Working on it.", sender: .agent, position: position(2))
        #expect(detector.shouldWarn)

        detector.observe(text: "⟦doc⟧not-even-valid-json", sender: .agent, position: position(3))
        #expect(!detector.shouldWarn)
    }

    @Test func startupTimeoutTracksProgressInsteadOfRetainedProvisioningObjects() {
        #expect(DocAgentStartupTimeoutPolicy.deadline == .seconds(90))
        #expect(!DocAgentStartupTimeoutPolicy.shouldFail(
            dmIsReady: false,
            startupWorkMadeProgress: true
        ))
        #expect(!DocAgentStartupTimeoutPolicy.shouldFail(
            dmIsReady: true,
            startupWorkMadeProgress: false
        ))
    }

    @Test func startupTimeoutSurfacesFailureWhenObjectsExistButRebindStalls() {
        let retainedStartupObjects = (conversationViewModel: true, agentDmSession: true)
        let scheduledProgressRevision = 4
        let currentProgressRevision = 4

        #expect(retainedStartupObjects.conversationViewModel)
        #expect(retainedStartupObjects.agentDmSession)
        #expect(DocAgentStartupTimeoutPolicy.shouldFail(
            dmIsReady: false,
            startupWorkMadeProgress: currentProgressRevision != scheduledProgressRevision
        ))
    }

    @MainActor
    @Test func resetClearsOnlyDocShellState() throws {
        let suiteName = "DocAgentResetTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let session = MockInboxesService()
        let docKeys = [
            "originConversationId",
            "welcome",
            "googleConnectHandled",
            "snapshot",
            "state",
            "control",
            "controlAgentInboxId",
            "controlResyncSentAgentInboxId",
        ]
            .map { DocExperienceViewModel.storageKey($0, session: session) }
        docKeys.forEach { defaults.set("stored", forKey: $0) }
        defaults.set("keep", forKey: "unrelated")

        DocExperienceViewModel.resetAgentBinding(session: session, defaults: defaults)

        #expect(docKeys.allSatisfy { defaults.object(forKey: $0) == nil })
        #expect(defaults.string(forKey: "unrelated") == "keep")
    }

    @MainActor
    @Test func resetDiscardsTheOldCreationWrapperBeforeStartingAgain() async throws {
        let suiteName = "DocAgentCreationResetTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let session = MockInboxesService()
        let wasDocModeEnabled = FeatureFlags.shared.isDocModeEnabled
        FeatureFlags.shared.isDocModeEnabled = false
        defer { FeatureFlags.shared.isDocModeEnabled = wasDocModeEnabled }
        let viewModel = DocExperienceViewModel(
            session: session,
            coreActions: NoOpCoreActions(),
            defaults: defaults
        )

        #expect(viewModel.firstRunStep == .prepareAgent)
        #expect(!viewModel.hasCompletedWelcome)
        await viewModel.startAgentIfNeeded()
        let firstWrapper = try #require(viewModel.conversationViewModel)

        DocExperienceViewModel.resetAgentBinding(session: session, defaults: defaults)
        try await Task.sleep(for: .milliseconds(10))

        #expect(viewModel.conversationViewModel == nil)
        #expect(viewModel.agentStartupState == .idle)
        #expect(viewModel.firstRunStep == .prepareAgent)

        await viewModel.startAgentIfNeeded()
        for _ in 0..<20 where viewModel.conversationViewModel == nil {
            try await Task.sleep(for: .milliseconds(10))
        }
        let secondWrapper = try #require(viewModel.conversationViewModel)

        #expect(firstWrapper !== secondWrapper)
        #expect(viewModel.agentStartupState == .preparing)
    }

    @MainActor
    @Test func verificationQueuesTheTapUntilTheAgentDmIsReady() throws {
        let suiteName = "DocVerificationQueueTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let viewModel = DocExperienceViewModel(
            session: MockInboxesService(),
            coreActions: NoOpCoreActions(),
            defaults: defaults
        )

        viewModel.requestPhoneVerification(number: "+14155550123")

        #expect(viewModel.isPhoneVerificationRequestQueued)
        #expect(viewModel.verificationFlowState == .enteringNumber)
        #expect(viewModel.verificationAgentStartupState == .preparing)
    }

    @Test func verificationStartupFailureReplacesTheSendSurface() {
        let message = "I couldn't open our private chat. Check your connection and try again."

        #expect(DocAgentStartupSurfaceState.resolve(
            startupState: .idle,
            dmIsReady: false
        ) == .preparing)
        #expect(DocAgentStartupSurfaceState.resolve(
            startupState: .failed(message),
            dmIsReady: false
        ) == .failed(message))
        #expect(DocAgentStartupSurfaceState.resolve(
            startupState: .failed(message),
            dmIsReady: true
        ) == .failed(message))
    }

    @Test func resolvedTombstonePreventsColdHistoryFromRestoringItem() throws {
        let item = waitingItem(id: "cold-item")
        var pendingItems = [item]
        var resolvedIds: Set<String> = []

        #expect(DocItemReconciler.apply(
            .itemResolved(id: item.id),
            pendingItems: &pendingItems,
            resolvedItemIds: &resolvedIds
        ))
        #expect(pendingItems.isEmpty)

        #expect(!DocItemReconciler.apply(
            .item(item),
            pendingItems: &pendingItems,
            resolvedItemIds: &resolvedIds
        ))
        #expect(pendingItems.isEmpty)
        #expect(resolvedIds == [item.id])
    }

    @Test func newerItemPayloadReplacesExistingPendingItem() throws {
        let original = waitingItem(id: "question", headline: "Old question")
        let updated = waitingItem(id: "question", headline: "Current question")
        var pendingItems = [original]
        var resolvedIds: Set<String> = []

        #expect(DocItemReconciler.apply(
            .item(updated),
            pendingItems: &pendingItems,
            resolvedItemIds: &resolvedIds
        ))
        #expect(pendingItems == [updated])
    }

    private func waitingItem(
        id: String,
        headline: String = "Which date works?"
    ) -> DocWaitingItem {
        DocWaitingItem(
            id: id,
            kind: .question,
            headline: headline,
            context: "Pick a date.",
            createdAt: Date(timeIntervalSince1970: 1)
        )
    }

    private func position(_ seconds: TimeInterval) -> DocMessagePosition {
        DocMessagePosition(
            date: Date(timeIntervalSince1970: seconds),
            messageId: "message-\(seconds)"
        )
    }
}
