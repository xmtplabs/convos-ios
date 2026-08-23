import ConvosCore
import XCTest
@testable import Convos

@MainActor
final class ConversationViewModelPendingDraftTests: XCTestCase {
    func testPendingDraftAppendsAfterExistingComposerText() {
        let conversationId: String = "pending-draft-append-\(UUID().uuidString)"
        let viewModel = makeViewModel(conversationId: conversationId)
        let store = PendingComposerDraftStore(environment: ConfigManager.shared.currentEnvironment)
        viewModel.messageText = "Unsent message"
        store.stage(PendingComposerDraft(
            conversationId: conversationId,
            text: "Copied agent reply",
            stagedAt: Date()
        ))

        viewModel.applyPendingComposerDraft()

        XCTAssertEqual(viewModel.messageText, "Unsent message\n\nCopied agent reply")
    }

    func testAppendedPendingDraftIsConsumed() {
        let conversationId: String = "pending-draft-consumed-\(UUID().uuidString)"
        let viewModel = makeViewModel(conversationId: conversationId)
        let store = PendingComposerDraftStore(environment: ConfigManager.shared.currentEnvironment)
        viewModel.messageText = "Unsent message\n\n"
        store.stage(PendingComposerDraft(
            conversationId: conversationId,
            text: "Copied agent reply",
            stagedAt: Date()
        ))

        viewModel.applyPendingComposerDraft()

        XCTAssertEqual(viewModel.messageText, "Unsent message\n\nCopied agent reply")
        XCTAssertNil(store.take(for: conversationId))
    }

    func testTypingAfterApplyingURLDraftDoesNotCreatePastedLinkPreview() {
        let conversationId: String = "pending-draft-url-\(UUID().uuidString)"
        let viewModel = makeViewModel(conversationId: conversationId)
        let store = PendingComposerDraftStore(environment: ConfigManager.shared.currentEnvironment)
        let draftText: String = "https://example.com"
        store.stage(PendingComposerDraft(
            conversationId: conversationId,
            text: draftText,
            stagedAt: Date()
        ))

        viewModel.applyPendingComposerDraft()
        viewModel.messageText = "\(draftText)a"
        viewModel.checkForPastedLink()

        XCTAssertEqual(viewModel.messageText, "\(draftText)a")
        XCTAssertNil(viewModel.pastedLinkPreview)
    }

    private func makeViewModel(conversationId: String) -> ConversationViewModel {
        ConversationViewModel(
            conversation: .mock(id: conversationId, name: "Draft test"),
            session: MockInboxesService(),
            messagingService: MockMessagingService()
        )
    }
}
