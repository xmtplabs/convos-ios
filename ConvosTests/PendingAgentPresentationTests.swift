@testable import Convos
import ConvosCore
import XCTest

/// Coverage for the unified optimistic pending-agent identity: the
/// `AgentShareInfo.optimisticCardMember` card vehicle and
/// `ConversationViewModel.pendingAgentPresentation` (generic builder case vs
/// identity-aware template case, plus the deep-link upgrade and the
/// real-agent teardown).
@MainActor
final class PendingAgentPresentationTests: XCTestCase {
    // MARK: - optimisticCardMember

    func testOptimisticCardMemberCarriesIdentityAndVerification() {
        let info = AgentShareInfo(
            templateId: "tid-123",
            displayName: "Tifoso",
            emoji: "🚴",
            descriptionText: "Plans your rides",
            avatarURL: "https://example.com/a.png"
        )

        let member = info.optimisticCardMember(conversationId: "conv-1")

        XCTAssertEqual(member.profile.inboxId, "optimistic-agent-tid-123",
                       "Sentinel inbox id should be derived from the template id")
        XCTAssertEqual(member.profile.conversationId, "conv-1")
        XCTAssertTrue(member.isAgent)
        XCTAssertTrue(member.isVerifiedConvosAgent,
                      "Optimistic card member should render with verified Convos styling")
        XCTAssertEqual(member.profile.name, "Tifoso")
        XCTAssertEqual(member.profile.profileEmoji, "🚴")
        XCTAssertEqual(member.profile.agentDescription, "Plans your rides")
    }

    func testNeutralPendingAgentHasNoIdentity() {
        let member = AgentShareInfo.neutralPendingAgent(templateId: "tid-9").optimisticCardMember(conversationId: "c")

        XCTAssertEqual(member.profile.inboxId, "optimistic-agent-tid-9")
        XCTAssertNil(member.profile.name)
        XCTAssertNil(member.profile.profileEmoji)
        XCTAssertNil(member.profile.agentDescription)
        XCTAssertTrue(member.isVerifiedConvosAgent)
    }

    // MARK: - pendingAgentPresentation

    func testNoPresentationWhenNotPending() {
        let viewModel = makeViewModel()

        XCTAssertNil(viewModel.pendingAgentPresentation)
        XCTAssertFalse(viewModel.shouldRenderAsPendingAgent)
    }

    func testTemplateIdentityPresentation() {
        let viewModel = makeViewModel()
        viewModel.activateOptimisticAgent(identity: AgentShareInfo(
            templateId: "tid",
            displayName: "Tifoso",
            emoji: "🚴",
            descriptionText: "Plans your rides",
            avatarURL: nil
        ))

        let presentation = viewModel.pendingAgentPresentation
        XCTAssertEqual(presentation?.name, "Tifoso")
        XCTAssertEqual(presentation?.emoji, "🚴")
        XCTAssertEqual(presentation?.showsContactCard, true)
        XCTAssertEqual(presentation?.avatarIdentity?.emoji, "🚴")

        XCTAssertEqual(viewModel.conversationName, "Tifoso")
        XCTAssertEqual(viewModel.untitledConversationPlaceholder, "Tifoso")
        XCTAssertEqual(viewModel.conversationInfoSubtitle, "Joining...")
    }

    func testNeutralPresentationHidesContactCard() {
        let viewModel = makeViewModel()
        viewModel.activateOptimisticAgent(identity: .neutralPendingAgent(templateId: "tid"))

        let presentation = viewModel.pendingAgentPresentation
        XCTAssertNotNil(presentation, "Neutral deep-link placeholder still renders as pending")
        XCTAssertNil(presentation?.name)
        XCTAssertEqual(presentation?.showsContactCard, false,
                       "No contact card until an identity (name/emoji) exists")
        XCTAssertNil(presentation?.avatarIdentity,
                     "No avatar identity -> falls back to the add-agent glyph")
        XCTAssertEqual(viewModel.untitledConversationPlaceholder, "Agent")
        XCTAssertEqual(viewModel.conversationInfoSubtitle, "Joining...")
    }

    func testDeepLinkIdentityUpgradesInPlace() {
        let viewModel = makeViewModel()
        viewModel.activateOptimisticAgent(identity: .neutralPendingAgent(templateId: "tid"))
        XCTAssertEqual(viewModel.pendingAgentPresentation?.showsContactCard, false)

        viewModel.applyOptimisticAgentIdentity(AgentShareInfo(
            templateId: "tid",
            displayName: "Sous",
            emoji: "🍳",
            descriptionText: nil,
            avatarURL: nil
        ))

        XCTAssertEqual(viewModel.pendingAgentPresentation?.name, "Sous")
        XCTAssertEqual(viewModel.pendingAgentPresentation?.emoji, "🍳")
        XCTAssertEqual(viewModel.pendingAgentPresentation?.showsContactCard, true)
    }

    func testRealVerifiedAgentDropsOptimisticPresentation() {
        let members: [ConversationMember] = [
            .mock(isCurrentUser: true),
            .mock(isAgent: true, agentVerification: .verified(.convos))
        ]
        let viewModel = makeViewModel(conversation: .mock(id: "test-convo", name: nil, members: members))
        viewModel.activateOptimisticAgent(identity: AgentShareInfo(
            templateId: "tid",
            displayName: "Tifoso",
            emoji: "🚴",
            descriptionText: nil,
            avatarURL: nil
        ))

        XCTAssertNil(viewModel.pendingAgentPresentation,
                     "A real verified Convos agent in members wins over the optimistic identity")
        XCTAssertFalse(viewModel.shouldRenderAsPendingAgent)
    }

    // MARK: - Helpers

    private func makeViewModel(
        conversation: Conversation = .mock(id: "test-convo", name: nil, members: [.mock(isCurrentUser: true)])
    ) -> ConversationViewModel {
        ConversationViewModel(
            conversation: conversation,
            session: MockInboxesService(),
            messagingService: MockMessagingService(),
            applyGlobalDefaultsForNewConversation: false
        )
    }
}
