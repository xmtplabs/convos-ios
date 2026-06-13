@testable import Convos
import ConvosCore
import XCTest

/// Regression coverage for the rule "no contact card for self." Tapping
/// your own avatar in the messages view, or your own row in the members
/// list, must route to "My info" via `presentingProfileSettings`, never
/// to the member contact-card sheet via `presentingProfileForMember`.
/// Showing the contact card for self exposes the Send-a-message and
/// Block affordances against yourself, which would silently upsert
/// `self` into the local contact table.
@MainActor
final class ConversationViewModelMemberTapTests: XCTestCase {
    func testTapOwnAvatarOpensProfileSettings() {
        let viewModel = makeViewModel()
        let selfMember = ConversationMember.mock(isCurrentUser: true)

        XCTAssertFalse(viewModel.presentingProfileSettings)
        XCTAssertNil(viewModel.presentingProfileForMember)

        viewModel.onTapAvatar(selfMember)

        XCTAssertTrue(viewModel.presentingProfileSettings,
                      "Tapping your own avatar should open My info")
        XCTAssertNil(viewModel.presentingProfileForMember,
                     "The member contact-card sheet must not open for self")
    }

    func testTapOtherMemberAvatarOpensContactCardSheet() {
        let viewModel = makeViewModel()
        let other = ConversationMember.mock(isCurrentUser: false, name: "Alice")

        viewModel.onTapAvatar(other)

        XCTAssertEqual(viewModel.presentingProfileForMember?.profile.inboxId,
                       other.profile.inboxId,
                       "Tapping a non-self member should open their contact card")
        XCTAssertFalse(viewModel.presentingProfileSettings,
                       "The My info sheet must not open for a non-self member")
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
}
