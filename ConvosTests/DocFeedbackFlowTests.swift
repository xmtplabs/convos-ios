@testable import Convos
import ConvosComposer
import ConvosCore
import Testing
import UIKit

@MainActor
struct DocFeedbackFlowTests {
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
