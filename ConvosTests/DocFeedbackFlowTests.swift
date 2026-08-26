@testable import Convos
import ConvosComposer
import ConvosCore
import Testing
import UIKit

@MainActor
struct DocFeedbackFlowTests {
    @Test("null-state home always has the Doc preview contribution line")
    func nullStateHomeHasContributionLine() throws {
        let suiteName = "DocContributionLineTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let viewModel = DocExperienceViewModel(
            session: MockInboxesService(),
            coreActions: NoOpCoreActions(),
            defaults: defaults
        )

        #expect(viewModel.docs.isEmpty)
        #expect(viewModel.contributionLine == DocPreviewConfiguration.contributionLine)
        #expect(docDisplayPhoneNumber(viewModel.contributionLine) == "+1 (628) 309-5734")
    }

    @Test("snapshot contribution line overrides the preview line")
    func snapshotContributionLineOverridesPreviewLine() {
        #expect(DocContributionLinePolicy.number(stateLine: "+14155550100") == "+14155550100")
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

    @Test("Google connect chains authorization directly into conversation grant")
    func googleConnectChainsGrant() async throws {
        var calls: [String] = []

        try await DocGoogleConnectionChain.connectAndGrant(
            existingConnection: {
                calls.append("lookup")
                return nil as String?
            },
            connect: {
                calls.append("connect")
                return "google-connection"
            },
            grant: { connection in
                calls.append("grant:\(connection)")
            }
        )

        #expect(calls == ["lookup", "connect", "grant:google-connection"])
    }

    @Test("Google connect reuses an active entitlement before granting")
    func googleConnectReusesExistingConnection() async throws {
        var calls: [String] = []

        try await DocGoogleConnectionChain.connectAndGrant(
            existingConnection: {
                calls.append("lookup")
                return "existing"
            },
            connect: {
                calls.append("connect")
                return "new"
            },
            grant: { connection in
                calls.append("grant:\(connection)")
            }
        )

        #expect(calls == ["lookup", "grant:existing"])
    }
}
