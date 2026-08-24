@testable import Convos
import ConvosCore
import XCTest

final class ContactDetailModeTests: XCTestCase {
    func testStandaloneModeReportsNonScoped() {
        let mode: ContactDetailMode = .standalone
        XCTAssertFalse(mode.isScopedToConversation)
        XCTAssertNil(mode.conversationId)
        XCTAssertFalse(mode.canRemoveMembers)
        XCTAssertFalse(mode.isCurrentUser)
    }

    func testScopedModeExposesPayload() {
        let mode: ContactDetailMode = .scopedToConversation(
            conversationId: "convo-1",
            canRemoveMembers: true,
            isCurrentUser: false,
            invitedBy: nil,
            joinedAt: nil
        )
        XCTAssertTrue(mode.isScopedToConversation)
        XCTAssertEqual(mode.conversationId, "convo-1")
        XCTAssertTrue(mode.canRemoveMembers)
        XCTAssertFalse(mode.isCurrentUser)
    }

    func testScopedModeCurrentUserFlag() {
        let mode: ContactDetailMode = .scopedToConversation(
            conversationId: "convo-1",
            canRemoveMembers: false,
            isCurrentUser: true,
            invitedBy: nil,
            joinedAt: nil
        )
        XCTAssertTrue(mode.isCurrentUser)
        XCTAssertFalse(mode.canRemoveMembers)
    }

    func testScopedModeRepairsStaleCurrentUserFlagFromAuthorizedInbox() {
        let mode: ContactDetailMode = .scopedToConversation(
            conversationId: "convo-1",
            canRemoveMembers: true,
            isCurrentUser: false,
            invitedBy: nil,
            joinedAt: nil
        )

        let resolved = mode.resolvingCurrentUser(
            contactInboxId: "inbox-shane",
            authorizedInboxId: "inbox-shane"
        )

        XCTAssertTrue(resolved.isCurrentUser)
        XCTAssertEqual(resolved.conversationId, "convo-1")
        XCTAssertTrue(resolved.canRemoveMembers)
    }

    func testScopedModeDoesNotTreatAnotherMemberAsCurrentUser() {
        let mode: ContactDetailMode = .scopedToConversation(
            conversationId: "convo-1",
            canRemoveMembers: true,
            isCurrentUser: false,
            invitedBy: nil,
            joinedAt: nil
        )

        let resolved = mode.resolvingCurrentUser(
            contactInboxId: "inbox-alice",
            authorizedInboxId: "inbox-shane"
        )

        XCTAssertFalse(resolved.isCurrentUser)
    }

    func testExistingCurrentUserFlagSurvivesUnavailableSessionIdentity() {
        let mode: ContactDetailMode = .scopedToConversation(
            conversationId: "convo-1",
            canRemoveMembers: false,
            isCurrentUser: true,
            invitedBy: nil,
            joinedAt: nil
        )

        let resolved = mode.resolvingCurrentUser(
            contactInboxId: "inbox-shane",
            authorizedInboxId: nil
        )

        XCTAssertTrue(resolved.isCurrentUser)
    }
}

final class ConversationGroupAgentOwnershipTests: XCTestCase {
    func testFindsPersonalAgentBeforeVerificationMetadataArrives() {
        let owner = Profile.mock(inboxId: "inbox-shane", name: "Shane")
        let agent = ConversationMember(
            profile: Profile.mock(inboxId: "agent-codex", name: "Codex"),
            role: .member,
            isCurrentUser: false,
            isAgent: true,
            agentVerification: .unverified,
            invitedBy: owner
        )
        let conversation = Conversation.mock(members: [
            ConversationMember(profile: owner, role: .admin, isCurrentUser: true),
            agent,
        ])

        XCTAssertEqual(
            conversation.groupAgentSetUp(by: owner.inboxId)?.profile.inboxId,
            agent.profile.inboxId
        )
    }

    func testDoesNotAttributeAnotherPersonsAgentToCurrentUser() {
        let owner = Profile.mock(inboxId: "inbox-shane", name: "Shane")
        let other = Profile.mock(inboxId: "inbox-alice", name: "Alice")
        let agent = ConversationMember(
            profile: Profile.mock(inboxId: "agent-town", name: "Town"),
            role: .member,
            isCurrentUser: false,
            isAgent: true,
            agentVerification: .verified(.userOAuth),
            invitedBy: other
        )
        let conversation = Conversation.mock(members: [
            ConversationMember(profile: owner, role: .admin, isCurrentUser: true),
            ConversationMember(profile: other, role: .member, isCurrentUser: false),
            agent,
        ])

        XCTAssertNil(conversation.groupAgentSetUp(by: owner.inboxId))
    }

    func testDoesNotTreatInvitedHumanAsGroupAgent() {
        let owner = Profile.mock(inboxId: "inbox-shane", name: "Shane")
        let invitedHuman = ConversationMember(
            profile: Profile.mock(inboxId: "inbox-bob", name: "Bob"),
            role: .member,
            isCurrentUser: false,
            invitedBy: owner
        )
        let conversation = Conversation.mock(members: [
            ConversationMember(profile: owner, role: .admin, isCurrentUser: true),
            invitedHuman,
        ])

        XCTAssertNil(conversation.groupAgentSetUp(by: owner.inboxId))
    }
}
