@testable import Convos
import ConvosCore
import XCTest

@MainActor
final class ConversationsViewModelComposeTests: XCTestCase {
    private func makeViewModel(contacts: [Contact]) -> ConversationsViewModel {
        let messaging = MockMessagingService()
        messaging.contactsToReturn = contacts
        let session = TestSessionManager(
            base: MockInboxesService(),
            messagingService: messaging
        )
        return ConversationsViewModel(session: session)
    }

    func testOnStartConvoSkipsPickerWhenNoContacts() {
        let viewModel = makeViewModel(contacts: [])

        viewModel.onStartConvo()

        XCTAssertNotNil(
            viewModel.newConversationViewModel,
            "With no contacts the picker is skipped and the new-conversation view opens directly"
        )
        XCTAssertFalse(viewModel.presentingComposeFlow)
        XCTAssertNil(viewModel.composeConversationViewModel)
    }

    func testOnStartConvoSkipsPickerWhenNoPickableContacts() {
        let viewModel = makeViewModel(contacts: [
            Contact.mock(displayName: "Convos Assistant", agentVerification: .verified(.convos)),
            Contact.mock(displayName: nil),
        ])

        viewModel.onStartConvo()

        XCTAssertNotNil(
            viewModel.newConversationViewModel,
            "Verified agents and unnamed contacts aren't pickable, so the picker is still skipped"
        )
        XCTAssertFalse(viewModel.presentingComposeFlow)
        XCTAssertNil(viewModel.composeConversationViewModel)
    }

    func testOnStartConvoShowsPickerWhenPickableContactsExist() {
        let viewModel = makeViewModel(contacts: [
            Contact.mock(displayName: "Alice"),
        ])

        viewModel.onStartConvo()

        XCTAssertTrue(
            viewModel.presentingComposeFlow,
            "A pickable contact presents the compose picker instead of skipping it"
        )
        XCTAssertNotNil(viewModel.composeConversationViewModel)
        XCTAssertNil(viewModel.newConversationViewModel)
    }

    func testOnStartConvoShowsPickerWhenMixOfPickableAndUnpickable() {
        let viewModel = makeViewModel(contacts: [
            Contact.mock(displayName: "Convos Assistant", agentVerification: .verified(.convos)),
            Contact.mock(displayName: "Alice"),
        ])

        viewModel.onStartConvo()

        XCTAssertTrue(
            viewModel.presentingComposeFlow,
            "A single pickable contact among unpickable ones is enough to present the picker"
        )
        XCTAssertNotNil(viewModel.composeConversationViewModel)
        XCTAssertNil(viewModel.newConversationViewModel)
    }
}
