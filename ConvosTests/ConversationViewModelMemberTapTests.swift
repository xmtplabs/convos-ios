@testable import Convos
import ConvosCore
import XCTest

/// Regression coverage for member-avatar routing. Every member, including
/// the current user, opens the canonical contact card. The card's current-user
/// mode is responsible for hiding unsafe self actions and showing the social
/// connected-agent profile.
@MainActor
final class ConversationViewModelMemberTapTests: XCTestCase {
    func testTapOwnAvatarOpensCurrentUserContactCard() {
        let viewModel = makeViewModel()
        let selfMember = ConversationMember.mock(isCurrentUser: true)

        XCTAssertFalse(viewModel.presentingProfileSettings)
        XCTAssertNil(viewModel.presentingProfileForMember)

        viewModel.onTapAvatar(selfMember)

        XCTAssertEqual(viewModel.presentingProfileForMember?.profile.inboxId,
                       selfMember.profile.inboxId,
                       "Tapping your own avatar should open your social profile card")
        XCTAssertFalse(viewModel.presentingProfileSettings,
                       "The profile editor should only open after choosing to edit")
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
