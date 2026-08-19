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
            activeConversationIds: []
        ))
    }

    @Test("Does not mark unread for our own message")
    func skipsOwnMessage() {
        #expect(!marksConversationUnread(
            contentType: .text,
            senderInboxId: me,
            currentInboxId: me,
            conversationId: conversationId,
            activeConversationIds: []
        ))
    }

    @Test("Does not mark unread for the conversation the user is viewing")
    func skipsActiveConversation() {
        #expect(!marksConversationUnread(
            contentType: .text,
            senderInboxId: other,
            currentInboxId: me,
            conversationId: conversationId,
            activeConversationIds: [conversationId]
        ))
    }

    @Test("Marks unread when a different conversation is active")
    func marksWhenDifferentConversationActive() {
        #expect(marksConversationUnread(
            contentType: .text,
            senderInboxId: other,
            currentInboxId: me,
            conversationId: conversationId,
            activeConversationIds: ["some-other-conversation"]
        ))
    }

    @Test("Does not mark unread for content types that never mark unread")
    func skipsNonUnreadContentTypes() {
        // `.update` (group membership) and the connection silent types never
        // mark a conversation unread, even from another sender.
        // `.capabilityRequest` deliberately left this list: a connect request
        // in the member's agent DM is discovered through the unread dot.
        for contentType: MessageContentType in [.update, .connectionEvent, .capabilityRequestResult, .connectionInvocation] {
            #expect(!marksConversationUnread(
                contentType: contentType,
                senderInboxId: other,
                currentInboxId: me,
                conversationId: conversationId,
                activeConversationIds: []
            ), "\(contentType) should not mark unread")
        }
    }
}
