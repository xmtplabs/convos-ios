@testable import ConvosCore
import Testing

/// Phase 2 batch 3: migrated from
/// `ConvosCore/Tests/ConvosCoreTests/ConversationIsPendingInviteTests.swift`.
///
/// Pure-unit coverage of `Conversation.isPendingInvite` using
/// `Conversation.mock(...)`. No backend, no DB — verbatim re-host.

@Suite("Conversation.isPendingInvite")
struct ConversationIsPendingInviteTests {
    @Test("Returns true for draft conversation with no current user member")
    func pendingInviteDraftNoCurrentUser() {
        let conversation = Conversation.mock(
            id: "draft-test-invite",
            members: [.mock(isCurrentUser: false)]
        )
        #expect(conversation.isPendingInvite == true)
    }

    @Test("Returns false for non-draft conversation")
    func notDraft() {
        let conversation = Conversation.mock(
            id: "real-conversation-id"
        )
        #expect(conversation.isPendingInvite == false)
    }

    @Test("Returns false for draft conversation where current user has joined")
    func draftWithCurrentUserJoined() {
        let conversation = Conversation.mock(
            id: "draft-joined",
            members: [.mock(isCurrentUser: true), .mock(isCurrentUser: false)]
        )
        #expect(conversation.isPendingInvite == false)
    }

    @Test("Returns false for regular conversation with default members")
    func regularConversation() {
        let conversation = Conversation.mock()
        #expect(conversation.isPendingInvite == false)
    }

    @Test("mockPendingInvite helper returns a pending invite")
    func mockPendingInviteHelper() {
        let conversation = Conversation.mockPendingInvite()
        #expect(conversation.isPendingInvite == true)
        #expect(conversation.isDraft == true)
        #expect(conversation.hasJoined == false)
    }
}
