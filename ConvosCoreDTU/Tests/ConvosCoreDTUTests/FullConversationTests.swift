@testable import ConvosCore
import Foundation
import Testing

/// Phase 2 batch 3: migrated from
/// `ConvosCore/Tests/ConvosCoreTests/FullConversationTests.swift`.
///
/// Pure-unit coverage of `Conversation.isFull` / `Conversation.maxMembers`.
/// No backend, no DB — verbatim re-host.

@Suite("Full Conversation Tests")
struct FullConversationTests {
    @Test("isFull returns false when member count is below maxMembers")
    func testIsFullReturnsFalseWhenBelowLimit() {
        let members = (0..<149).map { index in
            ConversationMember.mock(isCurrentUser: index == 0, name: "Member \(index)")
        }
        let conversation = Conversation.mock(members: members)

        #expect(conversation.isFull == false)
        #expect(conversation.members.count == 149)
    }

    @Test("isFull returns true when member count equals maxMembers")
    func testIsFullReturnsTrueAtExactLimit() {
        let members = (0..<Conversation.maxMembers).map { index in
            ConversationMember.mock(isCurrentUser: index == 0, name: "Member \(index)")
        }
        let conversation = Conversation.mock(members: members)

        #expect(conversation.isFull == true)
        #expect(conversation.members.count == Conversation.maxMembers)
    }

    @Test("isFull returns true when member count exceeds maxMembers")
    func testIsFullReturnsTrueWhenAboveLimit() {
        let members = (0..<151).map { index in
            ConversationMember.mock(isCurrentUser: index == 0, name: "Member \(index)")
        }
        let conversation = Conversation.mock(members: members)

        #expect(conversation.isFull == true)
        #expect(conversation.members.count == 151)
    }

    @Test("isFull returns false for empty conversation")
    func testIsFullReturnsFalseForEmptyConversation() {
        let conversation = Conversation.mock(members: [])

        #expect(conversation.isFull == false)
    }

    @Test("maxMembers constant equals 150")
    func testMaxMembersConstant() {
        #expect(Conversation.maxMembers == 150)
    }
}
