@testable import ConvosCore
import Foundation
import Testing

@Suite("CaughtUpMessageRouting")
struct CaughtUpMessageRoutingTests {
    private let conversationId = "conv-1"
    private let me = "inbox-me"
    private let other = "inbox-other"

    @Test("Marks unread for a user-visible message from another sender")
    func marksUnreadForOtherSender() {
        #expect(marksConversationUnread(
            contentType: .text,
            senderInboxId: other,
            currentInboxId: me,
            conversationId: conversationId,
            activeConversationId: nil
        ))
    }

    @Test("Does not mark unread for our own message")
    func skipsOwnMessage() {
        #expect(!marksConversationUnread(
            contentType: .text,
            senderInboxId: me,
            currentInboxId: me,
            conversationId: conversationId,
            activeConversationId: nil
        ))
    }

    @Test("Does not mark unread for the conversation the user is viewing")
    func skipsActiveConversation() {
        #expect(!marksConversationUnread(
            contentType: .text,
            senderInboxId: other,
            currentInboxId: me,
            conversationId: conversationId,
            activeConversationId: conversationId
        ))
    }

    @Test("Marks unread when a different conversation is active")
    func marksWhenDifferentConversationActive() {
        #expect(marksConversationUnread(
            contentType: .text,
            senderInboxId: other,
            currentInboxId: me,
            conversationId: conversationId,
            activeConversationId: "some-other-conversation"
        ))
    }

    @Test("Does not mark unread for content types that never mark unread")
    func skipsNonUnreadContentTypes() {
        // `.update` (group membership) and the connection/capability silent
        // types never mark a conversation unread, even from another sender.
        for contentType: MessageContentType in [.update, .connectionEvent, .capabilityRequest, .connectionInvocation] {
            #expect(!marksConversationUnread(
                contentType: contentType,
                senderInboxId: other,
                currentInboxId: me,
                conversationId: conversationId,
                activeConversationId: nil
            ), "\(contentType) should not mark unread")
        }
    }
}
