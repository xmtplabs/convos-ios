@testable import Convos
import ConvosCore
import XCTest

/// Coverage for the contact-card gate that keeps the silently-provisioned
/// default agent out of the transcript. Every conversation gets that agent,
/// so while it is the only other member the chat shows no card for it.
///
/// The rule is exercised through `ConversationViewModel.contactCardAgent(in:)`
/// because that is what the view model's initializers use to seed the
/// messages-list repository. Seeding through anything else is what previously
/// flashed the card on the first frame before the gate pulled it back.
@MainActor
final class DefaultAgentContactCardTests: XCTestCase {
    private func member(name: String, isAgent: Bool = false, isCurrentUser: Bool = false) -> ConversationMember {
        .mock(
            isCurrentUser: isCurrentUser,
            name: name,
            isAgent: isAgent,
            agentVerification: isAgent ? .verified(.convos) : .unverified
        )
    }

    func testNoContactCardWhileTheAgentIsTheOnlyOtherMember() {
        let conversation = Conversation.mock(
            name: nil,
            members: [
                member(name: "You", isCurrentUser: true),
                member(name: "Assistant", isAgent: true),
            ]
        )

        XCTAssertFalse(ConversationViewModel.showsContactCard(in: conversation))
        XCTAssertNil(ConversationViewModel.contactCardAgent(in: conversation),
                     "The default agent has no contact card while it is alone with the user")
    }

    func testContactCardReturnsOnceAPersonJoins() {
        let agent = member(name: "Assistant", isAgent: true)
        let conversation = Conversation.mock(
            name: nil,
            members: [
                member(name: "You", isCurrentUser: true),
                agent,
                member(name: "Alice"),
            ]
        )

        XCTAssertTrue(ConversationViewModel.showsContactCard(in: conversation))
        XCTAssertEqual(ConversationViewModel.contactCardAgent(in: conversation)?.profile.inboxId,
                       agent.profile.inboxId,
                       "With a person in the room the agent is a visible participant again")
    }

    func testAgentBuiltConversationKeepsItsCard() {
        let agent = member(name: "Tifoso", isAgent: true)
        let conversation = Conversation.mock(
            name: nil,
            members: [
                member(name: "You", isCurrentUser: true),
                agent,
            ],
            wasCreatedFromAgentBuilder: true
        )

        XCTAssertTrue(ConversationViewModel.showsContactCard(in: conversation),
                      "An agent the user deliberately built is not the silent default agent")
        XCTAssertEqual(ConversationViewModel.contactCardAgent(in: conversation)?.profile.inboxId,
                       agent.profile.inboxId)
    }

    func testNoAgentMeansNoCard() {
        let conversation = Conversation.mock(
            name: nil,
            members: [
                member(name: "You", isCurrentUser: true),
                member(name: "Alice"),
            ]
        )

        XCTAssertNil(ConversationViewModel.contactCardAgent(in: conversation))
    }
}
