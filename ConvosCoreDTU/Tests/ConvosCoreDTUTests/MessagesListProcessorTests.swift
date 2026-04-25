@testable import ConvosCore
import ConvosMessagingProtocols
import Foundation
import Testing

/// Phase 2 batch 3: migrated from
/// `ConvosCore/Tests/ConvosCoreTests/MessagesListProcessorTests.swift`.
///
/// Pure-unit test — exercises `MessagesListProcessor` over
/// `[AnyMessage]` -> `[MessagesListItemType]`. No `MessagingClient`,
/// no DB, no backend: the migration is a verbatim re-host into the
/// ConvosCoreDTU test target. No fixture needed.

// MARK: - Test Helpers

private let currentUser: ConversationMember = .mock(isCurrentUser: true)
private let otherUser: ConversationMember = .mock(isCurrentUser: false, name: "Alice")
private let thirdUser: ConversationMember = .mock(isCurrentUser: false, name: "Bob")

private func makeMessage(
    id: String = UUID().uuidString,
    sender: ConversationMember = otherUser,
    text: String = "Hello",
    date: Date = Date(),
    status: MessageStatus = .published,
    reactions: [MessageReaction] = []
) -> AnyMessage {
    .message(Message(
        id: id,
        sender: sender,
        source: sender.isCurrentUser ? .outgoing : .incoming,
        status: status,
        content: .text(text),
        date: date,
        reactions: reactions
    ), .existing)
}

private func makeReply(
    id: String = UUID().uuidString,
    sender: ConversationMember = otherUser,
    text: String = "Reply text",
    parentSender: ConversationMember = currentUser,
    parentText: String = "Original",
    date: Date = Date()
) -> AnyMessage {
    let parentMessage = Message(
        id: "parent-\(id)",
        sender: parentSender,
        source: parentSender.isCurrentUser ? .outgoing : .incoming,
        status: .published,
        content: .text(parentText),
        date: date.addingTimeInterval(-60),
        reactions: []
    )
    return .reply(MessageReply(
        id: id,
        sender: sender,
        source: sender.isCurrentUser ? .outgoing : .incoming,
        status: .published,
        content: .text(text),
        date: date,
        parentMessage: parentMessage,
        reactions: []
    ), .existing)
}

private func makeAttachment(
    id: String = UUID().uuidString,
    sender: ConversationMember = otherUser,
    date: Date = Date()
) -> AnyMessage {
    .message(Message(
        id: id,
        sender: sender,
        source: sender.isCurrentUser ? .outgoing : .incoming,
        status: .published,
        content: .attachment(HydratedAttachment(key: "https://example.com/photo.jpg")),
        date: date,
        reactions: []
    ), .existing)
}

private func makeUpdate(
    id: String = UUID().uuidString,
    date: Date = Date(),
    addedMembers: [ConversationMember] = [],
    removedMembers: [ConversationMember] = []
) -> AnyMessage {
    .message(Message(
        id: id,
        sender: otherUser,
        source: .incoming,
        status: .published,
        content: .update(ConversationUpdate(
            creator: otherUser,
            addedMembers: addedMembers.isEmpty ? [.mock(isCurrentUser: false, name: "NewMember")] : addedMembers,
            removedMembers: removedMembers,
            metadataChanges: []
        )),
        date: date,
        reactions: []
    ), .existing)
}

private func makeEmoji(
    id: String = UUID().uuidString,
    sender: ConversationMember = otherUser,
    emoji: String = "🔥",
    date: Date = Date()
) -> AnyMessage {
    .message(Message(
        id: id,
        sender: sender,
        source: sender.isCurrentUser ? .outgoing : .incoming,
        status: .published,
        content: .emoji(emoji),
        date: date,
        reactions: []
    ), .existing)
}

private func makeAssistantJoinRequest(
    id: String = UUID().uuidString,
    sender: ConversationMember = currentUser,
    status: AssistantJoinStatus = .pending,
    date: Date = Date()
) -> AnyMessage {
    .message(Message(
        id: id,
        sender: sender,
        source: sender.isCurrentUser ? .outgoing : .incoming,
        status: .published,
        content: .assistantJoinRequest(status: status, requestedByInboxId: sender.profile.inboxId),
        date: date,
        reactions: []
    ), .existing)
}

/// Extract just the message groups from processed items
private func groups(from items: [MessagesListItemType]) -> [MessagesGroup] {
    items.compactMap {
        if case .messages(let group) = $0 { return group }
        return nil
    }
}

/// Extract just the message IDs in order from processed items
private func messageIds(from items: [MessagesListItemType]) -> [String] {
    items.flatMap { item -> [String] in
        switch item {
        case .messages(let group):
            return group.messages.map { $0.messageId }
        case .update(let id, _, _):
            return [id]
        default:
            return []
        }
    }
}

/// Count item types
private func itemCounts(from items: [MessagesListItemType]) -> (dates: Int, groups: Int, updates: Int) {
    var dates = 0, groups = 0, updates = 0
    for item in items {
        switch item {
        case .date: dates += 1
        case .messages: groups += 1
        case .update: updates += 1
        default: break
        }
    }
    return (dates, groups, updates)
}

// MARK: - Basic Processing Tests

struct MessagesListProcessorTests {
    @Test("Empty input produces empty output")
    func emptyInput() {
        let result = MessagesListProcessor.process([])
        #expect(result.isEmpty)
    }

    @Test("Single message produces date separator + one group")
    func singleMessage() {
        let msg = makeMessage(sender: otherUser, text: "Hello")
        let result = MessagesListProcessor.process([msg])

        #expect(result.count == 2)
        if case .date = result[0] {} else {
            Issue.record("First item should be a date separator")
        }
        if case .messages(let group) = result[1] {
            #expect(group.messages.count == 1)
            #expect(group.isLastGroup == true)
        } else {
            Issue.record("Second item should be a messages group")
        }
    }

    @Test("First item is always a date separator")
    func firstItemIsDateSeparator() {
        let messages = (0..<5).map { i in
            makeMessage(id: "msg-\(i)", sender: otherUser, text: "Msg \(i)", date: Date())
        }
        let result = MessagesListProcessor.process(messages)
        if case .date = result[0] {} else {
            Issue.record("First item should be a date separator")
        }
    }
}

// MARK: - Sender Grouping

struct MessagesListProcessorSenderGroupingTests {
    @Test("Messages from same sender are grouped together")
    func sameSenderGrouped() {
        let now = Date()
        let messages = [
            makeMessage(id: "1", sender: otherUser, text: "Hello", date: now),
            makeMessage(id: "2", sender: otherUser, text: "How are you?", date: now.addingTimeInterval(10)),
            makeMessage(id: "3", sender: otherUser, text: "Anyone there?", date: now.addingTimeInterval(20)),
        ]
        let result = MessagesListProcessor.process(messages)
        let g = groups(from: result)
        #expect(g.count == 1)
        #expect(g[0].messages.count == 3)
    }

    @Test("Sender change creates new group")
    func senderChangeCreatesNewGroup() {
        let now = Date()
        let messages = [
            makeMessage(id: "1", sender: otherUser, text: "Hello", date: now),
            makeMessage(id: "2", sender: otherUser, text: "How are you?", date: now.addingTimeInterval(10)),
            makeMessage(id: "3", sender: currentUser, text: "I'm good!", date: now.addingTimeInterval(20)),
        ]
        let result = MessagesListProcessor.process(messages)
        let g = groups(from: result)
        #expect(g.count == 2)
        #expect(g[0].messages.count == 2)
        #expect(g[0].sender.isCurrentUser == false)
        #expect(g[1].messages.count == 1)
        #expect(g[1].sender.isCurrentUser == true)
    }

    @Test("Alternating senders create separate groups")
    func alternatingSenders() {
        let now = Date()
        let messages = [
            makeMessage(id: "1", sender: otherUser, text: "Hi", date: now),
            makeMessage(id: "2", sender: currentUser, text: "Hey", date: now.addingTimeInterval(10)),
            makeMessage(id: "3", sender: otherUser, text: "What's up?", date: now.addingTimeInterval(20)),
            makeMessage(id: "4", sender: currentUser, text: "Not much", date: now.addingTimeInterval(30)),
        ]
        let result = MessagesListProcessor.process(messages)
        let g = groups(from: result)
        #expect(g.count == 4)
    }

    @Test("Three different senders create three groups")
    func threeSenders() {
        let now = Date()
        let messages = [
            makeMessage(id: "1", sender: otherUser, text: "Alice says hi", date: now),
            makeMessage(id: "2", sender: thirdUser, text: "Bob says hi", date: now.addingTimeInterval(10)),
            makeMessage(id: "3", sender: currentUser, text: "Me too", date: now.addingTimeInterval(20)),
        ]
        let result = MessagesListProcessor.process(messages)
        let g = groups(from: result)
        #expect(g.count == 3)
    }
}

// MARK: - Message Order Preservation

struct MessagesListProcessorOrderTests {
    @Test("Messages within a group preserve input order")
    func orderWithinGroup() {
        let now = Date()
        let messages = [
            makeMessage(id: "first", sender: otherUser, text: "First", date: now),
            makeMessage(id: "second", sender: otherUser, text: "Second", date: now.addingTimeInterval(10)),
            makeMessage(id: "third", sender: otherUser, text: "Third", date: now.addingTimeInterval(20)),
        ]
        let result = MessagesListProcessor.process(messages)
        let g = groups(from: result)
        #expect(g[0].messages[0].messageId == "first")
        #expect(g[0].messages[1].messageId == "second")
        #expect(g[0].messages[2].messageId == "third")
    }

    @Test("Overall message order across groups is preserved")
    func orderAcrossGroups() {
        let now = Date()
        let messages = [
            makeMessage(id: "a1", sender: otherUser, text: "A1", date: now),
            makeMessage(id: "a2", sender: otherUser, text: "A2", date: now.addingTimeInterval(10)),
            makeMessage(id: "b1", sender: currentUser, text: "B1", date: now.addingTimeInterval(20)),
            makeMessage(id: "c1", sender: otherUser, text: "C1", date: now.addingTimeInterval(30)),
        ]
        let result = MessagesListProcessor.process(messages)
        let ids = messageIds(from: result)
        #expect(ids == ["a1", "a2", "b1", "c1"])
    }

    @Test("Replies are ordered like regular messages within their group")
    func repliesPreserveOrder() {
        let now = Date()
        let messages = [
            makeMessage(id: "msg-1", sender: otherUser, text: "Hello", date: now),
            makeReply(id: "reply-1", sender: otherUser, text: "Reply to you", date: now.addingTimeInterval(10)),
            makeMessage(id: "msg-2", sender: otherUser, text: "Another msg", date: now.addingTimeInterval(20)),
        ]
        let result = MessagesListProcessor.process(messages)
        let g = groups(from: result)
        #expect(g.count == 1)
        #expect(g[0].messages[0].messageId == "msg-1")
        #expect(g[0].messages[1].messageId == "reply-1")
        #expect(g[0].messages[2].messageId == "msg-2")
    }

    @Test("Mixed message types maintain chronological order")
    func mixedTypesChronological() {
        let now = Date()
        let messages = [
            makeMessage(id: "text-1", sender: otherUser, text: "Hi", date: now),
            makeEmoji(id: "emoji-1", sender: otherUser, emoji: "🔥", date: now.addingTimeInterval(5)),
            makeMessage(id: "text-2", sender: otherUser, text: "Cool right?", date: now.addingTimeInterval(10)),
        ]
        let result = MessagesListProcessor.process(messages)
        let g = groups(from: result)
        #expect(g.count == 1)
        #expect(g[0].messages[0].messageId == "text-1")
        #expect(g[0].messages[1].messageId == "emoji-1")
        #expect(g[0].messages[2].messageId == "text-2")
    }
}

// MARK: - Date Separator Tests

struct MessagesListProcessorDateSeparatorTests {
    @Test("No date separator between messages within one hour")
    func noSeparatorWithinHour() {
        let now = Date()
        let messages = [
            makeMessage(id: "1", sender: otherUser, date: now),
            makeMessage(id: "2", sender: otherUser, date: now.addingTimeInterval(59 * 60)),
        ]
        let result = MessagesListProcessor.process(messages)
        let counts = itemCounts(from: result)
        #expect(counts.dates == 1)
    }

    @Test("Date separator inserted when gap exceeds one hour")
    func separatorAfterOneHour() {
        let now = Date()
        let messages = [
            makeMessage(id: "1", sender: otherUser, date: now),
            makeMessage(id: "2", sender: otherUser, date: now.addingTimeInterval(3601)),
        ]
        let result = MessagesListProcessor.process(messages)
        let counts = itemCounts(from: result)
        #expect(counts.dates == 2)
    }

    @Test("Date separator breaks an ongoing group from same sender")
    func dateSeparatorBreaksGroup() {
        let now = Date()
        let messages = [
            makeMessage(id: "1", sender: otherUser, text: "Before gap", date: now),
            makeMessage(id: "2", sender: otherUser, text: "After gap", date: now.addingTimeInterval(3601)),
        ]
        let result = MessagesListProcessor.process(messages)
        let g = groups(from: result)
        #expect(g.count == 2)
        #expect(g[0].messages.count == 1)
        #expect(g[1].messages.count == 1)
    }

    @Test("Multiple date separators for multi-day conversation")
    func multiDaySeparators() {
        let now = Date()
        let messages = [
            makeMessage(id: "1", sender: otherUser, date: now),
            makeMessage(id: "2", sender: otherUser, date: now.addingTimeInterval(7200)),
            makeMessage(id: "3", sender: otherUser, date: now.addingTimeInterval(14400)),
        ]
        let result = MessagesListProcessor.process(messages)
        let counts = itemCounts(from: result)
        #expect(counts.dates == 3)
        #expect(counts.groups == 3)
    }

    @Test("Date separator position is correct between groups")
    func dateSeparatorPosition() {
        let now = Date()
        let messages = [
            makeMessage(id: "1", sender: otherUser, date: now),
            makeMessage(id: "2", sender: otherUser, date: now.addingTimeInterval(3601)),
        ]
        let result = MessagesListProcessor.process(messages)
        #expect(result.count == 4)
        if case .date = result[0] {} else { Issue.record("Expected date at index 0") }
        if case .messages = result[1] {} else { Issue.record("Expected messages at index 1") }
        if case .date = result[2] {} else { Issue.record("Expected date at index 2") }
        if case .messages = result[3] {} else { Issue.record("Expected messages at index 3") }
    }
}

// MARK: - Attachment Grouping Tests

struct MessagesListProcessorAttachmentTests {
    @Test("Attachment gets its own group even from same sender")
    func attachmentOwnGroup() {
        let now = Date()
        let messages = [
            makeMessage(id: "text-1", sender: otherUser, text: "Check this out", date: now),
            makeAttachment(id: "photo-1", sender: otherUser, date: now.addingTimeInterval(5)),
            makeMessage(id: "text-2", sender: otherUser, text: "Cool right?", date: now.addingTimeInterval(10)),
        ]
        let result = MessagesListProcessor.process(messages)
        let g = groups(from: result)
        #expect(g.count == 3)
        #expect(g[0].messages[0].messageId == "text-1")
        #expect(g[1].messages[0].messageId == "photo-1")
        #expect(g[2].messages[0].messageId == "text-2")
    }

    @Test("Consecutive attachments from same sender each get own group")
    func consecutiveAttachments() {
        let now = Date()
        let messages = [
            makeAttachment(id: "photo-1", sender: otherUser, date: now),
            makeAttachment(id: "photo-2", sender: otherUser, date: now.addingTimeInterval(5)),
        ]
        let result = MessagesListProcessor.process(messages)
        let g = groups(from: result)
        #expect(g.count == 2)
    }

    @Test("Attachment from different sender still creates separate group")
    func attachmentDifferentSender() {
        let now = Date()
        let messages = [
            makeMessage(id: "1", sender: otherUser, text: "Hi", date: now),
            makeAttachment(id: "photo", sender: currentUser, date: now.addingTimeInterval(5)),
        ]
        let result = MessagesListProcessor.process(messages)
        let g = groups(from: result)
        #expect(g.count == 2)
    }
}

// MARK: - Update Message Tests

struct MessagesListProcessorUpdateTests {
    @Test("Update breaks current group and appears as standalone item")
    func updateBreaksGroup() {
        let now = Date()
        let messages = [
            makeMessage(id: "1", sender: otherUser, text: "Before", date: now),
            makeUpdate(id: "update-1", date: now.addingTimeInterval(10)),
            makeMessage(id: "2", sender: otherUser, text: "After", date: now.addingTimeInterval(20)),
        ]
        let result = MessagesListProcessor.process(messages)
        let counts = itemCounts(from: result)
        #expect(counts.groups == 2)
        #expect(counts.updates == 1)
    }

    @Test("Update appears in correct position")
    func updatePosition() {
        let now = Date()
        let messages = [
            makeMessage(id: "1", sender: otherUser, text: "Before", date: now),
            makeUpdate(id: "update-1", date: now.addingTimeInterval(10)),
            makeMessage(id: "2", sender: otherUser, text: "After", date: now.addingTimeInterval(20)),
        ]
        let result = MessagesListProcessor.process(messages)
        if case .date = result[0] {} else { Issue.record("Expected date at 0") }
        if case .messages = result[1] {} else { Issue.record("Expected messages at 1") }
        if case .update = result[2] {} else { Issue.record("Expected update at 2") }
        if case .messages = result[3] {} else { Issue.record("Expected messages at 3") }
    }

    @Test("Consecutive updates appear sequentially")
    func consecutiveUpdates() {
        let now = Date()
        let messages = [
            makeUpdate(id: "update-1", date: now),
            makeUpdate(id: "update-2", date: now.addingTimeInterval(5)),
        ]
        let result = MessagesListProcessor.process(messages)
        let counts = itemCounts(from: result)
        #expect(counts.updates == 2)
        #expect(counts.groups == 0)
    }

    @Test("Non-visible updates are filtered out")
    func nonVisibleUpdatesFiltered() {
        let now = Date()
        let hiddenUpdate = AnyMessage.message(Message(
            id: "hidden",
            sender: otherUser,
            source: .incoming,
            status: .published,
            content: .update(ConversationUpdate(
                creator: otherUser,
                addedMembers: [],
                removedMembers: [],
                metadataChanges: [.init(field: .metadata, oldValue: nil, newValue: "data")]
            )),
            date: now,
            reactions: []
        ), .existing)

        let messages = [
            makeMessage(id: "1", sender: otherUser, text: "Hello", date: now),
            hiddenUpdate,
            makeMessage(id: "2", sender: otherUser, text: "World", date: now.addingTimeInterval(10)),
        ]
        let result = MessagesListProcessor.process(messages)
        let counts = itemCounts(from: result)
        #expect(counts.updates == 0)
        #expect(counts.groups == 1)
    }
}

// MARK: - Last Group Flags Tests

struct MessagesListProcessorLastGroupTests {
    @Test("Last group is marked isLastGroup")
    func lastGroupMarked() {
        let now = Date()
        let messages = [
            makeMessage(id: "1", sender: otherUser, text: "First", date: now),
            makeMessage(id: "2", sender: currentUser, text: "Second", date: now.addingTimeInterval(10)),
        ]
        let result = MessagesListProcessor.process(messages)
        let g = groups(from: result)
        #expect(g[0].isLastGroup == false)
        #expect(g[1].isLastGroup == true)
    }

    @Test("Last group sent by current user is marked")
    func lastCurrentUserGroupMarked() {
        let now = Date()
        let messages = [
            makeMessage(id: "1", sender: currentUser, text: "My first", date: now),
            makeMessage(id: "2", sender: otherUser, text: "Other's msg", date: now.addingTimeInterval(10)),
            makeMessage(id: "3", sender: currentUser, text: "My second", date: now.addingTimeInterval(20)),
            makeMessage(id: "4", sender: otherUser, text: "Last from other", date: now.addingTimeInterval(30)),
        ]
        let result = MessagesListProcessor.process(messages)
        let g = groups(from: result)
        #expect(g.count == 4)

        let currentUserGroups = g.filter { $0.sender.isCurrentUser }
        #expect(currentUserGroups.count == 2)

        let lastCurrentUserGroup = currentUserGroups.last!
        #expect(lastCurrentUserGroup.isLastGroupSentByCurrentUser == true)

        let firstCurrentUserGroup = currentUserGroups.first!
        #expect(firstCurrentUserGroup.isLastGroupSentByCurrentUser == false)
    }

    @Test("When only other user sends, no group is marked as last current user group")
    func noCurrentUserGroups() {
        let now = Date()
        let messages = [
            makeMessage(id: "1", sender: otherUser, text: "Hi", date: now),
            makeMessage(id: "2", sender: otherUser, text: "Hello?", date: now.addingTimeInterval(10)),
        ]
        let result = MessagesListProcessor.process(messages)
        let g = groups(from: result)
        #expect(g.count == 1)
        #expect(g[0].isLastGroupSentByCurrentUser == false)
    }

    @Test("Single current user group is both isLastGroup and isLastGroupSentByCurrentUser")
    func singleCurrentUserGroup() {
        let now = Date()
        let messages = [
            makeMessage(id: "1", sender: currentUser, text: "Solo", date: now),
        ]
        let result = MessagesListProcessor.process(messages)
        let g = groups(from: result)
        #expect(g.count == 1)
        #expect(g[0].isLastGroup == true)
        #expect(g[0].isLastGroupSentByCurrentUser == true)
    }
}

// MARK: - Only Visible To Sender Tests

struct MessagesListProcessorOnlyVisibleTests {
    @Test("Messages marked as onlyVisibleToSender when otherMemberCount is 0")
    func onlyVisibleWhenNoOtherMembers() {
        let now = Date()
        let messages = [
            makeMessage(id: "1", sender: currentUser, text: "Talking to myself", date: now),
        ]
        let result = MessagesListProcessor.process(messages, currentOtherMemberCount: 0)
        let g = groups(from: result)
        #expect(g[0].onlyVisibleToSender == true)
    }

    @Test("Messages not marked onlyVisibleToSender when others are present")
    func notOnlyVisibleWithOtherMembers() {
        let now = Date()
        let messages = [
            makeMessage(id: "1", sender: currentUser, text: "Hello everyone", date: now),
        ]
        let result = MessagesListProcessor.process(messages, currentOtherMemberCount: 2)
        let g = groups(from: result)
        #expect(g[0].onlyVisibleToSender == false)
    }

    @Test("Other user's messages are never marked onlyVisibleToSender")
    func otherUserNeverOnlyVisible() {
        let now = Date()
        let messages = [
            makeMessage(id: "1", sender: otherUser, text: "I'm here", date: now),
        ]
        let result = MessagesListProcessor.process(messages, currentOtherMemberCount: 0)
        let g = groups(from: result)
        #expect(g[0].onlyVisibleToSender == false)
    }

    @Test("Member join update changes visibility for subsequent messages")
    func memberJoinChangesVisibility() {
        let now = Date()
        let newMember = ConversationMember.mock(isCurrentUser: false, name: "NewPerson")
        let messages = [
            makeMessage(id: "1", sender: currentUser, text: "Alone", date: now),
            makeUpdate(id: "join", date: now.addingTimeInterval(10), addedMembers: [newMember]),
            makeMessage(id: "2", sender: currentUser, text: "Not alone", date: now.addingTimeInterval(20)),
        ]
        let result = MessagesListProcessor.process(messages, currentOtherMemberCount: 0)
        let g = groups(from: result)

        #expect(g[0].onlyVisibleToSender == true)
        #expect(g[1].onlyVisibleToSender == false)
    }

    @Test("isLastGroupBeforeOtherMembers marks the last only-visible group")
    func lastGroupBeforeOtherMembers() {
        let now = Date()
        let newMember = ConversationMember.mock(isCurrentUser: false, name: "NewPerson")
        let messages = [
            makeMessage(id: "1", sender: currentUser, text: "Msg 1", date: now),
            makeMessage(id: "2", sender: currentUser, text: "Msg 2", date: now.addingTimeInterval(5)),
            makeUpdate(id: "join", date: now.addingTimeInterval(10), addedMembers: [newMember]),
            makeMessage(id: "3", sender: currentUser, text: "After join", date: now.addingTimeInterval(20)),
        ]
        let result = MessagesListProcessor.process(messages, currentOtherMemberCount: 0)
        let g = groups(from: result)

        let onlyVisibleGroups = g.filter { $0.onlyVisibleToSender }
        #expect(onlyVisibleGroups.count == 1)
        #expect(onlyVisibleGroups[0].isLastGroupBeforeOtherMembers == true)
    }
}

// MARK: - Complex Scenarios

struct MessagesListProcessorComplexTests {
    @Test("Full conversation flow: messages, updates, attachments, time gaps")
    func fullConversationFlow() {
        let now = Date()
        let messages = [
            // initial messages
            makeMessage(id: "1", sender: otherUser, text: "Hey!", date: now),
            makeMessage(id: "2", sender: otherUser, text: "Welcome!", date: now.addingTimeInterval(10)),
            makeMessage(id: "3", sender: currentUser, text: "Thanks!", date: now.addingTimeInterval(20)),

            // member joins
            makeUpdate(id: "join", date: now.addingTimeInterval(30)),

            // more messages
            makeMessage(id: "4", sender: thirdUser, text: "Hi all!", date: now.addingTimeInterval(40)),

            // photo shared
            makeAttachment(id: "photo", sender: otherUser, date: now.addingTimeInterval(50)),

            // time gap > 1 hour
            makeMessage(id: "5", sender: otherUser, text: "Back!", date: now.addingTimeInterval(3700)),
            makeMessage(id: "6", sender: currentUser, text: "Me too", date: now.addingTimeInterval(3710)),
        ]

        let result = MessagesListProcessor.process(messages)
        let ids = messageIds(from: result)

        // verify all messages are present in order
        #expect(ids == ["1", "2", "3", "join", "4", "photo", "5", "6"])

        let counts = itemCounts(from: result)
        #expect(counts.dates == 2)
        #expect(counts.updates == 1)
        #expect(counts.groups >= 5)
    }

    @Test("Conversation with only updates produces no groups")
    func onlyUpdates() {
        let now = Date()
        let messages = [
            makeUpdate(id: "u1", date: now),
            makeUpdate(id: "u2", date: now.addingTimeInterval(10)),
        ]
        let result = MessagesListProcessor.process(messages)
        let counts = itemCounts(from: result)
        #expect(counts.groups == 0)
        #expect(counts.updates == 2)
    }

    @Test("Large message count preserves all messages")
    func largeMessageCount() {
        let now = Date()
        let messageCount = 500
        let senders = [currentUser, otherUser, thirdUser]
        let messages: [AnyMessage] = (0..<messageCount).map { i in
            let sender: ConversationMember = senders[i % 3]
            return makeMessage(
                id: "msg-\(i)",
                sender: sender,
                text: "Message \(i)",
                date: now.addingTimeInterval(Double(i) * 10)
            )
        }
        let result = MessagesListProcessor.process(messages)
        let ids = messageIds(from: result)
        #expect(ids.count == messageCount)

        for i in 0..<messageCount {
            #expect(ids[i] == "msg-\(i)")
        }
    }

    @Test("Messages with reactions are grouped normally")
    func messagesWithReactions() {
        let now = Date()
        let reactions = [MessageReaction.mock(emoji: "❤️", sender: currentUser)]
        let messages = [
            makeMessage(id: "1", sender: otherUser, text: "Like this?", date: now, reactions: reactions),
            makeMessage(id: "2", sender: otherUser, text: "And this?", date: now.addingTimeInterval(10)),
        ]
        let result = MessagesListProcessor.process(messages)
        let g = groups(from: result)
        #expect(g.count == 1)
        #expect(g[0].messages.count == 2)
    }

    @Test("Published and unpublished messages from same sender are in one group")
    func mixedStatusSameSender() {
        let now = Date()
        let messages = [
            makeMessage(id: "1", sender: currentUser, text: "Sent", date: now, status: .published),
            makeMessage(id: "2", sender: currentUser, text: "Sending...", date: now.addingTimeInterval(5), status: .unpublished),
        ]
        let result = MessagesListProcessor.process(messages)
        let g = groups(from: result)
        #expect(g.count == 1)
        #expect(g[0].messages.count == 2)
    }

    @Test("Update between same-sender messages creates two separate groups")
    func updateSplitsSameSender() {
        let now = Date()
        let messages = [
            makeMessage(id: "1", sender: otherUser, text: "Before", date: now),
            makeMessage(id: "2", sender: otherUser, text: "Before 2", date: now.addingTimeInterval(5)),
            makeUpdate(id: "upd", date: now.addingTimeInterval(10)),
            makeMessage(id: "3", sender: otherUser, text: "After", date: now.addingTimeInterval(20)),
            makeMessage(id: "4", sender: otherUser, text: "After 2", date: now.addingTimeInterval(25)),
        ]
        let result = MessagesListProcessor.process(messages)
        let g = groups(from: result)
        #expect(g.count == 2)
        #expect(g[0].messages.count == 2)
        #expect(g[1].messages.count == 2)
    }

    @Test("Attachment after text, then text, from same sender creates three groups")
    func textAttachmentTextPattern() {
        let now = Date()
        let messages = [
            makeMessage(id: "t1", sender: otherUser, text: "Look:", date: now),
            makeAttachment(id: "a1", sender: otherUser, date: now.addingTimeInterval(5)),
            makeMessage(id: "t2", sender: otherUser, text: "Nice right?", date: now.addingTimeInterval(10)),
        ]
        let result = MessagesListProcessor.process(messages)
        let g = groups(from: result)
        #expect(g.count == 3)
        #expect(g[0].messages[0].messageId == "t1")
        #expect(g[1].messages[0].messageId == "a1")
        #expect(g[2].messages[0].messageId == "t2")
    }

    @Test("Date separator + sender change + attachment in sequence")
    func dateSenderAttachmentSequence() {
        let now = Date()
        let messages = [
            makeMessage(id: "1", sender: otherUser, text: "Morning", date: now),
            makeMessage(id: "2", sender: currentUser, text: "Afternoon", date: now.addingTimeInterval(3601)),
            makeAttachment(id: "3", sender: currentUser, date: now.addingTimeInterval(3610)),
        ]
        let result = MessagesListProcessor.process(messages)
        let counts = itemCounts(from: result)
        #expect(counts.dates == 2)
        #expect(counts.groups == 3)
    }
}

// MARK: - Assistant Join Request Tests

struct MessagesListProcessorAssistantJoinTests {
    @Test("Only the last assistant join request is shown")
    func onlyLastAssistantJoinShown() {
        let now = Date()
        let messages = [
            makeAssistantJoinRequest(id: "aj-1", date: now.addingTimeInterval(-5)),
            makeMessage(id: "1", sender: otherUser, text: "Hello", date: now.addingTimeInterval(-3)),
            makeAssistantJoinRequest(id: "aj-2", date: now),
        ]
        let result = MessagesListProcessor.process(messages)
        let ajItems = result.filter {
            if case .assistantJoinStatus = $0 { return true }
            return false
        }
        #expect(ajItems.count == 1)
    }

    @Test("Assistant join request hidden if verified Convos assistant joined after")
    func hiddenAfterAgentJoined() {
        let now = Date()
        let agentMember = ConversationMember(
            profile: Profile(inboxId: "agent-1", name: "Convos Assistant", avatar: nil, isAgent: true),
            role: .member,
            isCurrentUser: false,
            isAgent: true,
            agentVerification: .verified(.convos)
        )
        let messages = [
            makeAssistantJoinRequest(id: "aj-1", date: now),
            AnyMessage.message(Message(
                id: "agent-joined",
                sender: otherUser,
                source: .incoming,
                status: .published,
                content: .update(ConversationUpdate(
                    creator: otherUser,
                    addedMembers: [agentMember],
                    removedMembers: [],
                    metadataChanges: []
                )),
                date: now.addingTimeInterval(5),
                reactions: []
            ), .existing),
        ]
        let result = MessagesListProcessor.process(messages)
        let ajItems = result.filter {
            if case .assistantJoinStatus = $0 { return true }
            return false
        }
        #expect(ajItems.isEmpty)
    }

    @Test("Assistant join request stays visible if only an unverified agent joined after")
    func stayVisibleAfterUnverifiedAgentJoined() {
        // Regression coverage: a CLI joiner advertises itself as memberKind=agent
        // but is not a verified Convos assistant. It must NOT dismiss the
        // pending assistant join status — the user is still waiting for the
        // real assistant.
        let now = Date()
        let unverifiedAgent = ConversationMember(
            profile: Profile(inboxId: "cli-bot-1", name: "CLI Bot", avatar: nil, isAgent: true),
            role: .member,
            isCurrentUser: false,
            isAgent: true,
            agentVerification: .unverified
        )
        let messages = [
            makeAssistantJoinRequest(id: "aj-1", date: now),
            AnyMessage.message(Message(
                id: "cli-bot-joined",
                sender: otherUser,
                source: .incoming,
                status: .published,
                content: .update(ConversationUpdate(
                    creator: otherUser,
                    addedMembers: [unverifiedAgent],
                    removedMembers: [],
                    metadataChanges: []
                )),
                date: now.addingTimeInterval(5),
                reactions: []
            ), .existing),
        ]
        let result = MessagesListProcessor.process(messages)
        let ajItems = result.filter {
            if case .assistantJoinStatus = $0 { return true }
            return false
        }
        #expect(ajItems.count == 1)
    }

    @Test("Expired assistant join request is not shown")
    func expiredAssistantJoinHidden() {
        let messages = [
            makeAssistantJoinRequest(
                id: "aj-1",
                status: .pending,
                date: Date().addingTimeInterval(-100)
            ),
        ]
        let result = MessagesListProcessor.process(messages)
        let ajItems = result.filter {
            if case .assistantJoinStatus = $0 { return true }
            return false
        }
        #expect(ajItems.isEmpty)
    }
}

// MARK: - Edge Cases

struct MessagesListProcessorEdgeCaseTests {
    @Test("Single attachment message produces date + group")
    func singleAttachment() {
        let msg = makeAttachment(sender: otherUser)
        let result = MessagesListProcessor.process([msg])
        #expect(result.count == 2)
        if case .date = result[0] {} else { Issue.record("Expected date") }
        if case .messages = result[1] {} else { Issue.record("Expected messages") }
    }

    @Test("Single update message produces just the update item")
    func singleUpdate() {
        let msg = makeUpdate()
        let result = MessagesListProcessor.process([msg])
        let counts = itemCounts(from: result)
        #expect(counts.updates == 1)
        #expect(counts.groups == 0)
        #expect(counts.dates == 0)
    }

    @Test("Group id is derived from first message id")
    func groupIdFromFirstMessage() {
        let now = Date()
        let messages = [
            makeMessage(id: "first-msg", sender: otherUser, text: "Hello", date: now),
            makeMessage(id: "second-msg", sender: otherUser, text: "World", date: now.addingTimeInterval(5)),
        ]
        let result = MessagesListProcessor.process(messages)
        let g = groups(from: result)
        #expect(g[0].id == "group-first-msg")
    }

    @Test("Rapidly alternating senders with many messages")
    func rapidAlternatingSenders() {
        let now = Date()
        let count = 100
        let messages = (0..<count).map { i in
            makeMessage(
                id: "msg-\(i)",
                sender: i % 2 == 0 ? otherUser : currentUser,
                text: "Msg \(i)",
                date: now.addingTimeInterval(Double(i))
            )
        }
        let result = MessagesListProcessor.process(messages)
        let g = groups(from: result)
        #expect(g.count == count)

        let ids = messageIds(from: result)
        for i in 0..<count {
            #expect(ids[i] == "msg-\(i)")
        }
    }
}
