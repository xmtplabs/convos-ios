@testable import ConvosCore
import Foundation
import Testing

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

private func makeAgentJoinRequest(
    id: String = UUID().uuidString,
    sender: ConversationMember = currentUser,
    status: AgentJoinStatus = .pending,
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

// Count item types
// swiftlint:disable:next large_tuple
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
    func lastCurrentUserGroupMarked() throws {
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

        let lastCurrentUserGroup = try #require(currentUserGroups.last)
        #expect(lastCurrentUserGroup.isLastGroupSentByCurrentUser == true)

        let firstCurrentUserGroup = try #require(currentUserGroups.first)
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

// MARK: - Agent Join Request Tests

struct MessagesListProcessorAgentJoinTests {
    @Test("Only the last agent join request is shown")
    func onlyLastAgentJoinShown() {
        let now = Date()
        let messages = [
            makeAgentJoinRequest(id: "aj-1", date: now.addingTimeInterval(-5)),
            makeMessage(id: "1", sender: otherUser, text: "Hello", date: now.addingTimeInterval(-3)),
            makeAgentJoinRequest(id: "aj-2", date: now),
        ]
        let result = MessagesListProcessor.process(messages)
        let ajItems = result.filter {
            if case .agentJoinStatus = $0 { return true }
            return false
        }
        #expect(ajItems.count == 1)
    }

    @Test("Agent join request hidden if verified Convos agent joined after")
    func hiddenAfterAgentJoined() {
        let now = Date()
        let agentMember = ConversationMember(
            profile: Profile(inboxId: "agent-1", conversationId: "test-conv", name: "Convos Agent", avatar: nil, isAgent: true),
            role: .member,
            isCurrentUser: false,
            isAgent: true,
            agentVerification: .verified(.convos)
        )
        let messages = [
            makeAgentJoinRequest(id: "aj-1", date: now),
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
            if case .agentJoinStatus = $0 { return true }
            return false
        }
        #expect(ajItems.isEmpty)
    }

    @Test("Agent join request hidden and joined update remains visible")
    func hiddenAfterAgentJoinedWhileUpdateStillShown() {
        let now = Date()
        let agentMember = ConversationMember(
            profile: Profile(inboxId: "agent-1", conversationId: "test-conv", name: "Agent", avatar: nil, isAgent: true),
            role: .member,
            isCurrentUser: false,
            isAgent: true,
            agentVerification: .verified(.convos)
        )
        let joinedUpdate = AnyMessage.message(Message(
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
        ), .existing)
        let messages = [
            makeAgentJoinRequest(id: "aj-1", date: now),
            joinedUpdate,
        ]

        let result = MessagesListProcessor.process(messages, currentOtherMemberCount: 1)

        let agentJoinStatuses = result.compactMap { item -> AgentJoinStatus? in
            if case .agentJoinStatus(let status, _, _) = item {
                return status
            }
            return nil
        }
        let updates = result.compactMap { item -> ConversationUpdate? in
            if case .update(_, let update, _) = item {
                return update
            }
            return nil
        }

        #expect(agentJoinStatuses.isEmpty)
        #expect(updates.count == 1)
        #expect(updates.first?.addedVerifiedAgent == true)
    }

    @Test("Agent join request hidden when an unverified agent joined after")
    func hiddenAfterUnverifiedAgentJoined() {
        // Real Convos agents may not have `agentVerification.isConvosAgent`
        // set yet at the moment the "agent joined" update is processed —
        // attestation/keyset resolution is async. Dev and local-environment
        // agents may never send attestation at all. Suppress the pending
        // "Agent is joining…" status as soon as any agent member joins —
        // the membership-add itself is the signal the request is fulfilled.
        let now = Date()
        let unverifiedAgent = ConversationMember(
            profile: Profile(inboxId: "agent-1", conversationId: "test-conv", name: "Agent", avatar: nil, isAgent: true),
            role: .member,
            isCurrentUser: false,
            isAgent: true,
            agentVerification: .unverified
        )
        let messages = [
            makeAgentJoinRequest(id: "aj-1", date: now),
            AnyMessage.message(Message(
                id: "agent-joined",
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
        let result = MessagesListProcessor.process(messages, currentOtherMemberCount: 1)
        let ajItems = result.filter {
            if case .agentJoinStatus = $0 { return true }
            return false
        }
        #expect(ajItems.isEmpty)
    }

    @Test("Expired agent join request is not shown")
    func expiredAgentJoinHidden() {
        let messages = [
            makeAgentJoinRequest(
                id: "aj-1",
                status: .pending,
                date: Date().addingTimeInterval(-100)
            ),
        ]
        let result = MessagesListProcessor.process(messages)
        let ajItems = result.filter {
            if case .agentJoinStatus = $0 { return true }
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
                sender: i.isMultiple(of: 2) ? otherUser : currentUser,
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

// MARK: - Read Receipt Tests

struct MessagesListProcessorReadReceiptTests {
    @Test("Read-by member preserves agentVerification for verified Convos agent")
    func readByMemberPreservesVerification() {
        let now = Date()
        let agent: ConversationMember = .mock(
            isCurrentUser: false,
            name: "Convos Agent",
            isAgent: true,
            agentVerification: .verified(.convos)
        )
        let messages = [
            makeMessage(id: "asst-1", sender: agent, text: "Hi there", date: now),
            makeMessage(id: "me-1", sender: currentUser, text: "Hi back", date: now.addingTimeInterval(10)),
        ]
        let readAtNs = Int64(now.addingTimeInterval(20).timeIntervalSince1970 * 1_000_000_000)
        let receipts = [
            ReadReceiptEntry(inboxId: agent.profile.inboxId, readAtNs: readAtNs),
        ]
        let result = MessagesListProcessor.process(
            messages,
            readReceipts: receipts,
            currentOtherMemberCount: 1
        )
        let g = groups(from: result)
        let lastCurrentUserGroup = g.last { $0.isLastGroupSentByCurrentUser }
        #expect(lastCurrentUserGroup != nil)
        let readers = lastCurrentUserGroup?.readByMembers ?? []
        #expect(readers.count == 1)
        #expect(readers.first?.profile.inboxId == agent.profile.inboxId)
        #expect(readers.first?.agentVerification == .verified(.convos))
    }

    @Test("Read-by members carry mixed verification end-to-end")
    func readByMembersMixedVerification() {
        let now = Date()
        let agent: ConversationMember = .mock(
            isCurrentUser: false,
            name: "Convos Agent",
            isAgent: true,
            agentVerification: .verified(.convos)
        )
        let oauthAgent: ConversationMember = .mock(
            isCurrentUser: false,
            name: "OAuth Agent",
            isAgent: true,
            agentVerification: .verified(.userOAuth)
        )
        let regular: ConversationMember = .mock(isCurrentUser: false, name: "Alice")
        let messages = [
            makeMessage(id: "asst-1", sender: agent, text: "asst hi", date: now),
            makeMessage(id: "oauth-1", sender: oauthAgent, text: "oauth hi", date: now.addingTimeInterval(1)),
            makeMessage(id: "reg-1", sender: regular, text: "reg hi", date: now.addingTimeInterval(2)),
            makeMessage(id: "me-1", sender: currentUser, text: "Hi all", date: now.addingTimeInterval(10)),
        ]
        let readAtNs = Int64(now.addingTimeInterval(20).timeIntervalSince1970 * 1_000_000_000)
        let receipts = [
            ReadReceiptEntry(inboxId: agent.profile.inboxId, readAtNs: readAtNs),
            ReadReceiptEntry(inboxId: oauthAgent.profile.inboxId, readAtNs: readAtNs + 1),
            ReadReceiptEntry(inboxId: regular.profile.inboxId, readAtNs: readAtNs + 2),
        ]
        let result = MessagesListProcessor.process(
            messages,
            readReceipts: receipts,
            currentOtherMemberCount: 3
        )
        let g = groups(from: result)
        let lastCurrentUserGroup = g.last { $0.isLastGroupSentByCurrentUser }
        let readers = lastCurrentUserGroup?.readByMembers ?? []
        #expect(readers.count == 3)
        let byInbox = Dictionary(uniqueKeysWithValues: readers.map { ($0.profile.inboxId, $0.agentVerification) })
        #expect(byInbox[agent.profile.inboxId] == .verified(.convos))
        #expect(byInbox[oauthAgent.profile.inboxId] == .verified(.userOAuth))
        #expect(byInbox[regular.profile.inboxId] == .unverified)
    }

    @Test("Read-by members fall back to memberProfiles cache as unverified")
    func readByMembersFallbackToCache() {
        let now = Date()
        let conversationId = "conv-1"
        let absentInboxId = "absent-reader"
        let messages = [
            makeMessage(id: "me-1", sender: currentUser, text: "Hello", date: now),
        ]
        let readAtNs = Int64(now.addingTimeInterval(5).timeIntervalSince1970 * 1_000_000_000)
        let receipts = [
            ReadReceiptEntry(inboxId: absentInboxId, readAtNs: readAtNs),
        ]
        let memberProfiles: [String: MemberProfileInfo] = [
            absentInboxId: MemberProfileInfo(
                inboxId: absentInboxId,
                conversationId: conversationId,
                name: "Absent Reader",
                avatar: nil
            ),
        ]
        let result = MessagesListProcessor.process(
            messages,
            readReceipts: receipts,
            memberProfiles: memberProfiles,
            currentOtherMemberCount: 1
        )
        let g = groups(from: result)
        let readers = g.last { $0.isLastGroupSentByCurrentUser }?.readByMembers ?? []
        #expect(readers.count == 1)
        #expect(readers.first?.profile.inboxId == absentInboxId)
        #expect(readers.first?.agentVerification == .unverified)
    }

    @Test("Read-by members resolved from the memberProfiles cache keep their agent verification")
    func readByMembersFallbackPreservesAgentVerification() {
        let now = Date()
        let conversationId = "conv-1"
        let convosAgentInboxId = "quiet-convos-agent"
        let oauthAgentInboxId = "quiet-oauth-agent"
        let messages = [
            makeMessage(id: "me-1", sender: currentUser, text: "Hello", date: now),
        ]
        let readAtNs = Int64(now.addingTimeInterval(5).timeIntervalSince1970 * 1_000_000_000)
        let receipts = [
            ReadReceiptEntry(inboxId: convosAgentInboxId, readAtNs: readAtNs),
            ReadReceiptEntry(inboxId: oauthAgentInboxId, readAtNs: readAtNs + 1),
        ]
        let memberProfiles: [String: MemberProfileInfo] = [
            convosAgentInboxId: MemberProfileInfo(
                inboxId: convosAgentInboxId,
                conversationId: conversationId,
                name: "Quiet Convos Agent",
                avatar: nil,
                isAgent: true,
                agentVerification: .verified(.convos)
            ),
            oauthAgentInboxId: MemberProfileInfo(
                inboxId: oauthAgentInboxId,
                conversationId: conversationId,
                name: "Quiet OAuth Agent",
                avatar: nil,
                isAgent: true,
                agentVerification: .verified(.userOAuth)
            ),
        ]
        let result = MessagesListProcessor.process(
            messages,
            readReceipts: receipts,
            memberProfiles: memberProfiles,
            currentOtherMemberCount: 2
        )
        let g = groups(from: result)
        let readers = g.last { $0.isLastGroupSentByCurrentUser }?.readByMembers ?? []
        #expect(readers.count == 2)
        let byInbox = Dictionary(uniqueKeysWithValues: readers.map { ($0.profile.inboxId, $0) })
        #expect(byInbox[convosAgentInboxId]?.isAgent == true)
        #expect(byInbox[convosAgentInboxId]?.agentVerification == .verified(.convos))
        #expect(byInbox[oauthAgentInboxId]?.isAgent == true)
        #expect(byInbox[oauthAgentInboxId]?.agentVerification == .verified(.userOAuth))
    }
}

// MARK: - Agent Builder Card Reconstruction Tests

private func builderCards(from items: [MessagesListItemType]) -> [AgentBuilderCardContent] {
    items.compactMap {
        if case .agentBuilderSummary(let content) = $0 { return content }
        return nil
    }
}

private func builderSummary(
    bundledMessageIds: Set<String>,
    connectionIdentifiers: [String] = [],
    existingConversation: Bool = false,
    prompt: String = ""
) -> AgentBuilderSummary {
    AgentBuilderSummary(
        prompt: prompt,
        attachments: connectionIdentifiers.map { .connection(id: UUID(), identifier: $0) },
        cutoffDate: Date(),
        bundledMessageIds: bundledMessageIds,
        existingConversation: existingConversation
    )
}

struct MessagesListProcessorAgentBuilderCardTests {
    @Test("Recipient rebuilds the card from the bundle messages, positioned where Make happened")
    func recipientReconstruction() {
        let now = Date()
        let messages = [
            makeMessage(id: "hey", sender: otherUser, text: "Hey", date: now),
            makeAttachment(id: "b-att", sender: currentUser, date: now.addingTimeInterval(10)),
            makeMessage(id: "b-text", sender: currentUser, text: "Track the fog", date: now.addingTimeInterval(11)),
            makeMessage(id: "later", sender: otherUser, text: "Cool", date: now.addingTimeInterval(20)),
        ]
        let result = MessagesListProcessor.process(
            messages,
            hiddenBundleMessageIds: ["b-att", "b-text"]
        )

        // The raw bundle bubbles never render.
        #expect(messageIds(from: result) == ["hey", "later"])

        let cards = builderCards(from: result)
        #expect(cards.count == 1)
        #expect(cards.first?.prompt == "Track the fog")
        #expect(cards.first?.attachments.count == 1)

        // Card sits between the prior message and the later one.
        let cardIndex = result.firstIndex { if case .agentBuilderSummary = $0 { return true }; return false }
        let laterIndex = result.firstIndex {
            if case .messages(let group) = $0 { return group.messages.contains { $0.messageId == "later" } }
            return false
        }
        let heyIndex = result.firstIndex {
            if case .messages(let group) = $0 { return group.messages.contains { $0.messageId == "hey" } }
            return false
        }
        #expect(cardIndex != nil && heyIndex != nil && laterIndex != nil)
        if let cardIndex, let heyIndex, let laterIndex {
            #expect(heyIndex < cardIndex)
            #expect(cardIndex < laterIndex)
        }
    }

    @Test("Sender rebuilds the card from bundledMessageIds even when the hidden set is empty")
    func senderReconstructionViaBundledMessageIds() {
        let now = Date()
        let messages = [
            makeMessage(id: "hey", sender: otherUser, text: "Hey", date: now),
            makeMessage(id: "b-text", sender: currentUser, text: "Be my assistant", date: now.addingTimeInterval(10)),
        ]
        // hiddenBundleMessageIds empty (own manifest not yet round-tripped); only
        // the local summary knows the bundle ids.
        let result = MessagesListProcessor.process(
            messages,
            agentBuilderSummary: builderSummary(bundledMessageIds: ["b-text"], prompt: "Be my assistant"),
            hiddenBundleMessageIds: []
        )
        #expect(messageIds(from: result) == ["hey"])
        let cards = builderCards(from: result)
        #expect(cards.count == 1)
        #expect(cards.first?.prompt == "Be my assistant")
        #expect(cards.first?.creatorIsCurrentUser == true)
    }

    @Test("Hidden ids present but bundle messages absent renders no card and no bare bubbles")
    func hiddenIdsWithoutMessages() {
        let now = Date()
        let messages = [
            makeMessage(id: "hey", sender: otherUser, text: "Hey", date: now),
            makeMessage(id: "later", sender: otherUser, text: "Still here", date: now.addingTimeInterval(10)),
        ]
        let result = MessagesListProcessor.process(
            messages,
            hiddenBundleMessageIds: ["b-att", "b-text"]
        )
        #expect(builderCards(from: result).isEmpty)
        #expect(messageIds(from: result) == ["hey", "later"])
    }

    @Test("Date separator above the bundle is kept, anchored by the card")
    func dateSeparatorAnchoredByCard() {
        let now = Date()
        let messages = [
            makeMessage(id: "hey", sender: otherUser, text: "Morning", date: now),
            // > 1 hour later: a new date window starts at the bundle.
            makeMessage(id: "b-text", sender: currentUser, text: "New agent", date: now.addingTimeInterval(7200)),
        ]
        let result = MessagesListProcessor.process(
            messages,
            hiddenBundleMessageIds: ["b-text"]
        )
        let counts = itemCounts(from: result)
        #expect(counts.dates == 2)
        #expect(builderCards(from: result).count == 1)
        // Last item is the card, preceded by its date separator.
        if case .agentBuilderSummary = result.last {} else {
            Issue.record("Expected the card as the last item")
        }
    }

    @Test("Contact card lands directly under the builder card in the home flow")
    func contactCardUnderBuilderCard() {
        let now = Date()
        let agent: ConversationMember = .mock(
            isCurrentUser: false,
            name: "Agent",
            isAgent: true,
            agentVerification: .verified(.convos)
        )
        let messages = [
            makeMessage(id: "hey", sender: otherUser, text: "Hey", date: now),
            makeMessage(id: "b-text", sender: currentUser, text: "Make it", date: now.addingTimeInterval(10)),
        ]
        let result = MessagesListProcessor.process(
            messages,
            verifiedAgent: agent,
            agentBuilderSummary: builderSummary(bundledMessageIds: ["b-text"]),
            hiddenBundleMessageIds: ["b-text"],
            isInAgentBuilderFlow: true
        )
        let cardIndex = result.firstIndex { if case .agentBuilderSummary = $0 { return true }; return false }
        let contactCardIndex = result.firstIndex {
            if case .messages(let group) = $0 { return group.agentContactCard != nil }
            return false
        }
        #expect(cardIndex != nil)
        #expect(contactCardIndex != nil)
        if let cardIndex, let contactCardIndex {
            #expect(contactCardIndex == cardIndex + 1)
        }
    }

    @Test("Summary stays above the contact card even when the agent joined before Make")
    func summaryAboveContactCardWhenAgentJoinedFirst() {
        let now = Date()
        let agent = ConversationMember(
            profile: Profile(inboxId: "agent-1", conversationId: "conv", name: "Trail Roller", avatar: nil, isAgent: true),
            role: .member,
            isCurrentUser: false,
            isAgent: true,
            agentVerification: .verified(.convos)
        )
        // Home flow: the agent joins *before* the Make bundle is sent.
        let messages = [
            AnyMessage.message(Message(
                id: "agent-joined",
                sender: otherUser,
                source: .incoming,
                status: .published,
                content: .update(ConversationUpdate(
                    creator: otherUser,
                    addedMembers: [agent],
                    removedMembers: [],
                    metadataChanges: []
                )),
                date: now,
                reactions: []
            ), .existing),
            makeMessage(id: "b-text", sender: currentUser, text: "Plan my trip", date: now.addingTimeInterval(10)),
        ]
        // isInAgentBuilderFlow false -> the join row is NOT suppressed and sorts
        // above the summary, reproducing the contact-card-first ordering bug.
        let result = MessagesListProcessor.process(
            messages,
            verifiedAgent: agent,
            agentBuilderSummary: builderSummary(bundledMessageIds: ["b-text"]),
            hiddenBundleMessageIds: ["b-text"],
            isInAgentBuilderFlow: false
        )
        let cardIndex = result.firstIndex { if case .agentBuilderSummary = $0 { return true }; return false }
        let contactCardIndex = result.firstIndex {
            if case .messages(let group) = $0 { return group.agentContactCard != nil }
            return false
        }
        #expect(cardIndex != nil)
        #expect(contactCardIndex != nil)
        if let cardIndex, let contactCardIndex {
            #expect(cardIndex < contactCardIndex)
        }
    }

    @Test("Two separate Make events render two cards")
    func multipleBuildRuns() {
        let now = Date()
        let messages = [
            makeMessage(id: "hey", sender: otherUser, text: "Hey", date: now),
            makeMessage(id: "b1", sender: currentUser, text: "First agent", date: now.addingTimeInterval(10)),
            makeMessage(id: "mid", sender: otherUser, text: "Interesting", date: now.addingTimeInterval(20)),
            makeMessage(id: "b2", sender: currentUser, text: "Second agent", date: now.addingTimeInterval(30)),
            makeMessage(id: "later", sender: otherUser, text: "Nice", date: now.addingTimeInterval(40)),
        ]
        let result = MessagesListProcessor.process(
            messages,
            hiddenBundleMessageIds: ["b1", "b2"]
        )
        let cards = builderCards(from: result)
        #expect(cards.count == 2)
        #expect(Set(cards.map(\.prompt)) == ["First agent", "Second agent"])
        #expect(messageIds(from: result) == ["hey", "mid", "later"])
    }

    @Test("Recipient card attributes the creator and shows no connection chips")
    func recipientAttributionAndNoConnections() {
        let now = Date()
        let messages = [
            makeMessage(id: "b-text", sender: otherUser, text: "Alice's agent", date: now),
        ]
        let result = MessagesListProcessor.process(
            messages,
            hiddenBundleMessageIds: ["b-text"]
        )
        let card = builderCards(from: result).first
        #expect(card?.creatorIsCurrentUser == false)
        #expect(card?.creatorDisplayName == "Alice")
        #expect(card?.connectionIdentifiers.isEmpty == true)
    }

    @Test("Creator card carries the connection identifiers from the local summary")
    func creatorConnectionChips() {
        let now = Date()
        let messages = [
            makeMessage(id: "b-text", sender: currentUser, text: "Calendar agent", date: now),
        ]
        let result = MessagesListProcessor.process(
            messages,
            agentBuilderSummary: builderSummary(
                bundledMessageIds: ["b-text"],
                connectionIdentifiers: ["googleCalendar"]
            ),
            hiddenBundleMessageIds: ["b-text"]
        )
        let card = builderCards(from: result).first
        #expect(card?.connectionIdentifiers == ["googleCalendar"])
        #expect(card?.creatorIsCurrentUser == true)
    }
}

// MARK: - Contact Card Placement Tests

private let verifiedAgentMember: ConversationMember = .mock(
    isCurrentUser: false,
    name: "Agent",
    isAgent: true,
    agentVerification: .verified(.convos)
)

private func contactCardIndex(in items: [MessagesListItemType]) -> Int? {
    items.firstIndex {
        if case .messages(let group) = $0 { return group.agentContactCard != nil }
        return false
    }
}

private func contactCardCount(in items: [MessagesListItemType]) -> Int {
    items.count {
        if case .messages(let group) = $0 { return group.agentContactCard != nil }
        return false
    }
}

private func summaryIndices(in items: [MessagesListItemType]) -> [Int] {
    items.indices.filter {
        if case .agentBuilderSummary = items[$0] { return true }
        return false
    }
}

private func contactCardGroup(in items: [MessagesListItemType]) -> MessagesGroup? {
    groups(from: items).first { $0.agentContactCard != nil }
}

struct MessagesListProcessorContactCardPlacementTests {
    @Test("Contact card is a standalone row and never attaches to the agent's message group")
    func cardIsStandaloneRow() {
        let now = Date()
        let messages = [
            makeMessage(id: "b-text", sender: currentUser, text: "Make it", date: now),
            makeMessage(id: "greeting", sender: verifiedAgentMember, text: "Hi, I'm here!", date: now.addingTimeInterval(10)),
        ]
        let result = MessagesListProcessor.process(
            messages,
            verifiedAgent: verifiedAgentMember,
            agentBuilderSummary: builderSummary(bundledMessageIds: ["b-text"]),
            hiddenBundleMessageIds: ["b-text"]
        )
        let cardGroup = contactCardGroup(in: result)
        #expect(cardGroup != nil)
        #expect(cardGroup?.allMessages.isEmpty == true)
        // The greeting group carries its messages but not the card.
        let greetingGroup = groups(from: result).first { group in
            group.messages.contains { $0.messageId == "greeting" }
        }
        #expect(greetingGroup != nil)
        #expect(greetingGroup?.agentContactCard == nil)
    }

    @Test("Contact card stays anchored under the summary when rows land between it and the agent's first message")
    func cardDoesNotMoveWhenRowsIntervene() {
        let now = Date()
        let summaryOnly = [
            makeMessage(id: "b-text", sender: currentUser, text: "Make it", date: now),
        ]
        let withInterveningRows = [
            makeMessage(id: "b-text", sender: currentUser, text: "Make it", date: now),
            makeMessage(id: "user-extra", sender: currentUser, text: "Also do this", date: now.addingTimeInterval(5)),
            makeMessage(id: "greeting", sender: verifiedAgentMember, text: "On it!", date: now.addingTimeInterval(10)),
        ]
        let summary = builderSummary(bundledMessageIds: ["b-text"])

        let before = MessagesListProcessor.process(
            summaryOnly,
            verifiedAgent: verifiedAgentMember,
            agentBuilderSummary: summary,
            hiddenBundleMessageIds: ["b-text"]
        )
        let after = MessagesListProcessor.process(
            withInterveningRows,
            verifiedAgent: verifiedAgentMember,
            agentBuilderSummary: summary,
            hiddenBundleMessageIds: ["b-text"]
        )

        // The card sits directly under the summary in both passes -- it does
        // not jump down to the agent's first message group once it exists.
        for items in [before, after] {
            let summaryIndex = items.firstIndex { if case .agentBuilderSummary = $0 { return true }; return false }
            #expect(summaryIndex != nil)
            if let summaryIndex {
                #expect(contactCardIndex(in: items) == summaryIndex + 1)
            }
        }
    }

    @Test("Card anchors after the join row and merges visually with the agent group directly below")
    func cardAnchorsOnJoinRowAndMergesWithAdjacentAgentGroup() {
        let now = Date()
        let messages = [
            makeUpdate(id: "agent-joined", date: now, addedMembers: [verifiedAgentMember]),
            makeMessage(id: "greeting", sender: verifiedAgentMember, text: "Hello!", date: now.addingTimeInterval(5)),
        ]
        let result = MessagesListProcessor.process(
            messages,
            verifiedAgent: verifiedAgentMember
        )
        let joinIndex = result.firstIndex {
            guard case .update(_, let update, _) = $0 else { return false }
            return update.addedVerifiedAgent
        }
        #expect(joinIndex != nil)
        if let joinIndex {
            #expect(contactCardIndex(in: result) == joinIndex + 1)
        }
        // Adjacent pair renders as one run: the card defers its avatar and
        // the group below hides its duplicate sender label.
        #expect(contactCardGroup(in: result)?.contactCardPrecedesAgentMessages == true)
        let greetingGroup = groups(from: result).first { group in
            group.messages.contains { $0.messageId == "greeting" }
        }
        #expect(greetingGroup?.hidesSenderLabel == true)
    }

    @Test("Adjacency flags stay off when another sender's group sits below the card")
    func noAdjacencyFlagsWhenOtherSenderBelow() {
        let now = Date()
        let messages = [
            makeMessage(id: "b-text", sender: currentUser, text: "Make it", date: now),
            makeMessage(id: "user-extra", sender: currentUser, text: "One more thing", date: now.addingTimeInterval(5)),
            makeMessage(id: "greeting", sender: verifiedAgentMember, text: "Done!", date: now.addingTimeInterval(10)),
        ]
        let result = MessagesListProcessor.process(
            messages,
            verifiedAgent: verifiedAgentMember,
            agentBuilderSummary: builderSummary(bundledMessageIds: ["b-text"]),
            hiddenBundleMessageIds: ["b-text"]
        )
        #expect(contactCardGroup(in: result)?.contactCardPrecedesAgentMessages == false)
        let userGroup = groups(from: result).first { group in
            group.messages.contains { $0.messageId == "user-extra" }
        }
        #expect(userGroup?.hidesSenderLabel == false)
    }

    @Test("Without a summary or join row the card sits before the agent's first message group")
    func cardFallsBackToAgentFirstGroup() {
        let now = Date()
        let messages = [
            makeMessage(id: "user-text", sender: currentUser, text: "Hi", date: now),
            makeMessage(id: "greeting", sender: verifiedAgentMember, text: "Hello!", date: now.addingTimeInterval(5)),
        ]
        let result = MessagesListProcessor.process(
            messages,
            verifiedAgent: verifiedAgentMember
        )
        let cardIndex = contactCardIndex(in: result)
        let greetingIndex = result.firstIndex {
            guard case .messages(let group) = $0 else { return false }
            return group.messages.contains { $0.messageId == "greeting" }
        }
        #expect(cardIndex != nil)
        #expect(greetingIndex != nil)
        if let cardIndex, let greetingIndex {
            #expect(cardIndex == greetingIndex - 1)
        }
        #expect(contactCardGroup(in: result)?.contactCardPrecedesAgentMessages == true)
    }

    @Test("Card stays under its own summary when a later Make adds a second summary card")
    func cardStaysOnOwnSummaryWhenSecondSummaryAppears() {
        let now = Date()
        let messages = [
            makeUpdate(id: "agent-joined", date: now, addedMembers: [verifiedAgentMember]),
            makeMessage(id: "b1", sender: currentUser, text: "First agent", date: now.addingTimeInterval(10)),
            makeMessage(id: "greeting", sender: verifiedAgentMember, text: "Hello!", date: now.addingTimeInterval(20)),
            makeMessage(id: "mid", sender: currentUser, text: "Another one please", date: now.addingTimeInterval(30)),
            makeMessage(id: "b2", sender: currentUser, text: "Second agent", date: now.addingTimeInterval(40)),
        ]
        let result = MessagesListProcessor.process(
            messages,
            verifiedAgent: verifiedAgentMember,
            hiddenBundleMessageIds: ["b1", "b2"]
        )
        let summaries = summaryIndices(in: result)
        #expect(summaries.count == 2)
        // The card anchors on the first summary (the Make that created this
        // agent), not the latest one further down the list.
        if let firstSummary = summaries.first {
            #expect(contactCardIndex(in: result) == firstSummary + 1)
        }
        #expect(contactCardCount(in: result) == 1)
    }

    @Test("Join-row anchor matches this agent's join, not another verified agent's")
    func joinAnchorIgnoresOtherAgentsJoinRows() {
        let now = Date()
        let otherAgent: ConversationMember = .mock(
            isCurrentUser: false,
            name: "OtherAgent",
            isAgent: true,
            agentVerification: .verified(.convos)
        )
        let messages = [
            makeUpdate(id: "other-joined", date: now, addedMembers: [otherAgent]),
            makeMessage(id: "user-text", sender: currentUser, text: "Hi", date: now.addingTimeInterval(5)),
            makeUpdate(id: "agent-joined", date: now.addingTimeInterval(10), addedMembers: [verifiedAgentMember]),
        ]
        let result = MessagesListProcessor.process(
            messages,
            verifiedAgent: verifiedAgentMember
        )
        let agentJoinIndex = result.firstIndex {
            guard case .update(_, let update, _) = $0 else { return false }
            return update.addedMembers.contains { $0.profile.inboxId == verifiedAgentMember.profile.inboxId }
        }
        #expect(agentJoinIndex != nil)
        if let agentJoinIndex {
            #expect(contactCardIndex(in: result) == agentJoinIndex + 1)
        }
        #expect(contactCardCount(in: result) == 1)
    }

    @Test("Re-added agent anchors on its latest join row, below its older messages")
    func reAddedAgentAnchorsOnLatestJoinRow() {
        let now = Date()
        let messages = [
            makeUpdate(id: "join-1", date: now, addedMembers: [verifiedAgentMember]),
            makeMessage(id: "old-msg", sender: verifiedAgentMember, text: "First stint", date: now.addingTimeInterval(5)),
            makeUpdate(id: "join-2", date: now.addingTimeInterval(20), addedMembers: [verifiedAgentMember]),
        ]
        let result = MessagesListProcessor.process(
            messages,
            verifiedAgent: verifiedAgentMember
        )
        let joinIndices = result.indices.filter {
            guard case .update(_, let update, _) = result[$0] else { return false }
            return update.addedVerifiedAgent
        }
        #expect(joinIndices.count == 2)
        if let latestJoin = joinIndices.last {
            #expect(contactCardIndex(in: result) == latestJoin + 1)
        }
        #expect(contactCardCount(in: result) == 1)
    }

    @Test("Without any anchor the card sits at the top of the list")
    func cardFallsBackToTopWhenNoAnchorsExist() {
        let now = Date()
        let messages = [
            makeMessage(id: "user-text", sender: currentUser, text: "Hi", date: now),
        ]
        let result = MessagesListProcessor.process(
            messages,
            verifiedAgent: verifiedAgentMember
        )
        #expect(contactCardIndex(in: result) == 0)
        #expect(contactCardCount(in: result) == 1)
    }

    @Test("No merge flags when a non-message row sits directly below the insertion point")
    func noMergeFlagsWhenUpdateRowBelowInsertionPoint() {
        let now = Date()
        let messages = [
            makeMessage(id: "b1", sender: currentUser, text: "Make it", date: now),
            makeUpdate(id: "member-joined", date: now.addingTimeInterval(10)),
        ]
        let result = MessagesListProcessor.process(
            messages,
            verifiedAgent: verifiedAgentMember,
            hiddenBundleMessageIds: ["b1"]
        )
        let summaries = summaryIndices(in: result)
        #expect(summaries.count == 1)
        if let summary = summaries.first {
            #expect(contactCardIndex(in: result) == summary + 1)
        }
        #expect(contactCardGroup(in: result)?.contactCardPrecedesAgentMessages == false)
        #expect(contactCardCount(in: result) == 1)
    }
}

// Coverage for the creator-side optimistic card: after Make, the bundle send
// is held until the agent joins (OutgoingMessageWriter.waitForAgentMember), so
// the build's message rows don't exist yet and the run-anchored reconstruction
// has nothing to render. The processor must show the card from the summary
// alone within the pending window, hand off to the run-anchored card once the
// rows land, and never resurrect a card for an old row-less summary.
struct MessagesListProcessorPendingBuilderCardTests {
    @Test("Summary with no landed rows renders the card optimistically")
    func pendingCardRendersBeforeRowsLand() {
        let summary = AgentBuilderSummary(
            prompt: "Be my assistant",
            attachments: [],
            cutoffDate: Date(),
            bundledMessageIds: ["b-att", "b-text"]
        )
        let result = MessagesListProcessor.process(
            [],
            agentBuilderSummary: summary,
            hiddenBundleMessageIds: []
        )
        let cards = builderCards(from: result)
        #expect(cards.count == 1)
        #expect(cards.first?.prompt == "Be my assistant")
        #expect(cards.first?.creatorIsCurrentUser == true)
    }

    @Test("Once the summary's rows land, only the run-anchored card renders")
    func pendingCardHandsOffToRunAnchoredCard() {
        let now = Date()
        let messages = [
            makeMessage(id: "b-text", sender: currentUser, text: "Be my assistant", date: now),
        ]
        let summary = AgentBuilderSummary(
            prompt: "Be my assistant",
            attachments: [],
            cutoffDate: now,
            bundledMessageIds: ["b-text"]
        )
        let result = MessagesListProcessor.process(
            messages,
            agentBuilderSummary: summary,
            hiddenBundleMessageIds: []
        )
        let cards = builderCards(from: result)
        #expect(cards.count == 1)
        #expect(messageIds(from: result).isEmpty)
    }

    @Test("An old summary whose rows are gone does not resurrect a card")
    func expiredPendingSummaryRendersNoCard() {
        let summary = AgentBuilderSummary(
            prompt: "Be my assistant",
            attachments: [],
            cutoffDate: Date().addingTimeInterval(-3600),
            bundledMessageIds: ["b-att", "b-text"]
        )
        let result = MessagesListProcessor.process(
            [],
            agentBuilderSummary: summary,
            hiddenBundleMessageIds: []
        )
        #expect(builderCards(from: result).isEmpty)
    }

    @Test("Pending card carries the summary's connection identifiers")
    func pendingCardCarriesConnections() {
        let summary = AgentBuilderSummary(
            prompt: "Track my calendar",
            attachments: [.connection(id: UUID(), identifier: "googleCalendar")],
            cutoffDate: Date(),
            bundledMessageIds: ["b-text"]
        )
        let result = MessagesListProcessor.process(
            [],
            agentBuilderSummary: summary,
            hiddenBundleMessageIds: []
        )
        let cards = builderCards(from: result)
        #expect(cards.first?.connectionIdentifiers == ["googleCalendar"])
        #expect(cards.first?.attachments.isEmpty == true)
    }
}

extension MessagesListProcessorPendingBuilderCardTests {
    @Test("Verified agent's contact card anchors under the pending summary card")
    func contactCardAnchorsUnderPendingCard() {
        let agent = verifiedAgentMember
        let summary = AgentBuilderSummary(
            prompt: "Be my assistant",
            attachments: [],
            cutoffDate: Date(),
            bundledMessageIds: ["b-text"]
        )
        // The agent has joined (verified) but the build's rows haven't landed
        // yet -- the window right after the join gate opens. The pending card
        // must render and the contact card must anchor directly beneath it.
        let result = MessagesListProcessor.process(
            [],
            verifiedAgent: agent,
            agentBuilderSummary: summary,
            hiddenBundleMessageIds: []
        )
        let cards = builderCards(from: result)
        #expect(cards.count == 1)
        let summaryIndex = result.firstIndex { if case .agentBuilderSummary = $0 { return true } else { return false } }
        let contactIndex = result.firstIndex { item in
            guard case .messages(let group) = item else { return false }
            return group.agentContactCard != nil
        }
        #expect(summaryIndex != nil)
        #expect(contactIndex != nil)
        if let summaryIndex, let contactIndex {
            #expect(contactIndex == summaryIndex + 1)
        }
    }
}

extension MessagesListProcessorPendingBuilderCardTests {
    @Test("Messages sent while the bundle is held render below the pending card")
    func pendingCardStaysChronological() {
        let now = Date()
        let messages = [
            makeMessage(id: "before", sender: otherUser, text: "Earlier chat", date: now.addingTimeInterval(-60)),
            makeMessage(id: "after", sender: currentUser, text: "Sent during the hold", date: now.addingTimeInterval(30)),
        ]
        let summary = AgentBuilderSummary(
            prompt: "Be my assistant",
            attachments: [],
            cutoffDate: now,
            bundledMessageIds: ["b-text"]
        )
        let result = MessagesListProcessor.process(
            messages,
            agentBuilderSummary: summary,
            hiddenBundleMessageIds: []
        )
        let cardIndex = result.firstIndex { if case .agentBuilderSummary = $0 { return true } else { return false } }
        let beforeIndex = result.firstIndex { item in
            guard case .messages(let group) = item else { return false }
            return group.messages.contains { $0.messageId == "before" }
        }
        let afterIndex = result.firstIndex { item in
            guard case .messages(let group) = item else { return false }
            return group.messages.contains { $0.messageId == "after" }
        }
        #expect(cardIndex != nil && beforeIndex != nil && afterIndex != nil)
        if let cardIndex, let beforeIndex, let afterIndex {
            #expect(beforeIndex < cardIndex)
            #expect(cardIndex < afterIndex)
        }
    }
}

extension MessagesListProcessorPendingBuilderCardTests {
    @Test("Card stays at the Make position after the held bundle publishes below later messages")
    func cardStaysAtMakePositionAfterRowsLand() {
        let make = Date()
        let messages = [
            makeMessage(id: "before", sender: otherUser, text: "Earlier chat", date: make.addingTimeInterval(-60)),
            makeMessage(id: "during", sender: currentUser, text: "Sent during the hold", date: make.addingTimeInterval(30)),
            // The bundle publishes only after the agent joins, so its row is
            // dated later than the message sent during the hold.
            makeMessage(id: "b-text", sender: currentUser, text: "Be my assistant", date: make.addingTimeInterval(60)),
        ]
        let summary = AgentBuilderSummary(
            prompt: "Be my assistant",
            attachments: [],
            cutoffDate: make,
            bundledMessageIds: ["b-text"]
        )
        let result = MessagesListProcessor.process(
            messages,
            agentBuilderSummary: summary,
            hiddenBundleMessageIds: []
        )
        let cards = builderCards(from: result)
        #expect(cards.count == 1)
        #expect(messageIds(from: result) == ["before", "during"])
        let cardIndex = result.firstIndex { if case .agentBuilderSummary = $0 { return true } else { return false } }
        let beforeIndex = result.firstIndex { item in
            guard case .messages(let group) = item else { return false }
            return group.messages.contains { $0.messageId == "before" }
        }
        let duringIndex = result.firstIndex { item in
            guard case .messages(let group) = item else { return false }
            return group.messages.contains { $0.messageId == "during" }
        }
        if let cardIndex, let beforeIndex, let duringIndex {
            #expect(beforeIndex < cardIndex)
            #expect(cardIndex < duringIndex)
        }
    }

    @Test("Existing conversation with unloaded history defers the card instead of pinning it at the top")
    func emptySnapshotDefersCardForExistingConversation() {
        let summary = AgentBuilderSummary(
            prompt: "Be my assistant",
            attachments: [],
            cutoffDate: Date(),
            bundledMessageIds: ["b-text"],
            existingConversation: true
        )
        let result = MessagesListProcessor.process(
            [],
            agentBuilderSummary: summary,
            hiddenBundleMessageIds: []
        )
        #expect(builderCards(from: result).isEmpty)
    }
}

extension MessagesListProcessorPendingBuilderCardTests {
    @Test("Same-sender messages spanning Make split around the card instead of dragging it to the top")
    func cardSplitsMergedGroupAtMakeBoundary() {
        let make = Date()
        // All from the current user, consecutive -- the processor merges them
        // into one group spanning the Make boundary.
        let messages = [
            makeMessage(id: "pre-1", sender: currentUser, text: "Hi", date: make.addingTimeInterval(-120)),
            makeMessage(id: "pre-2", sender: currentUser, text: "Setting up", date: make.addingTimeInterval(-60)),
            makeMessage(id: "post-1", sender: currentUser, text: "Sent right after Make", date: make.addingTimeInterval(20)),
            makeMessage(id: "post-2", sender: currentUser, text: "And another", date: make.addingTimeInterval(40)),
        ]
        let summary = AgentBuilderSummary(
            prompt: "Be my assistant",
            attachments: [],
            cutoffDate: make,
            bundledMessageIds: ["b-text"]
        )
        let result = MessagesListProcessor.process(
            messages,
            agentBuilderSummary: summary,
            hiddenBundleMessageIds: []
        )
        #expect(builderCards(from: result).count == 1)
        let cardIndex = result.firstIndex { if case .agentBuilderSummary = $0 { return true } else { return false } }
        func groupIndex(containing id: String) -> Int? {
            result.firstIndex { item in
                guard case .messages(let group) = item else { return false }
                return group.messages.contains { $0.messageId == id }
            }
        }
        #expect(cardIndex != nil)
        if let cardIndex {
            #expect(groupIndex(containing: "pre-2")! < cardIndex)
            #expect(cardIndex < groupIndex(containing: "post-1")!)
        }
        // No message is lost in the split.
        #expect(Set(messageIds(from: result)) == ["pre-1", "pre-2", "post-1", "post-2"])
    }

    @Test("Make-boundary split keeps the Sent row only on the newer half")
    func makeBoundarySplitKeepsSingleSentRow() {
        let make = Date()
        let messages = [
            makeMessage(id: "pre", sender: currentUser, text: "Before Make", date: make.addingTimeInterval(-60)),
            makeMessage(id: "post", sender: currentUser, text: "After Make", date: make.addingTimeInterval(20)),
        ]
        let summary = AgentBuilderSummary(
            prompt: "Be my assistant",
            attachments: [],
            cutoffDate: make,
            bundledMessageIds: ["b-text"]
        )
        let result = MessagesListProcessor.process(
            messages,
            agentBuilderSummary: summary,
            hiddenBundleMessageIds: []
        )
        let flagged = groups(from: result).filter(\.isLastGroupSentByCurrentUser)
        #expect(flagged.count == 1)
        #expect(flagged.first?.messages.map(\.messageId) == ["post"])
    }
}

extension MessagesListProcessorPendingBuilderCardTests {
    @Test("Messages straddling the swallowed build bundle stay one group with one Sent row")
    func messagesAroundSwallowedBundleStayGrouped() {
        let make = Date()
        // The user sends one message right after Make, the agent joins and the
        // held bundle publishes (its row dated between the sends), then the
        // user sends again. All rows share a sender, so the processor merges
        // them into one group; swallowing the bundle row must not split it.
        let messages = [
            makeMessage(id: "please", sender: currentUser, text: "Please", date: make.addingTimeInterval(5)),
            makeMessage(id: "b-text", sender: currentUser, text: "Help me get healthier", date: make.addingTimeInterval(12)),
            makeMessage(id: "ugh", sender: currentUser, text: "Ugh", date: make.addingTimeInterval(20)),
        ]
        let summary = AgentBuilderSummary(
            prompt: "Help me get healthier",
            attachments: [],
            cutoffDate: make,
            bundledMessageIds: ["b-text"]
        )
        let result = MessagesListProcessor.process(
            messages,
            agentBuilderSummary: summary,
            hiddenBundleMessageIds: ["b-text"]
        )
        #expect(builderCards(from: result).count == 1)
        let g = groups(from: result)
        #expect(g.count == 1)
        #expect(g.first?.messages.map(\.messageId) == ["please", "ugh"])
        #expect(g.filter(\.isLastGroupSentByCurrentUser).count == 1)

        // The card renders at the Make slot, above both sends.
        let cardIndex = result.firstIndex { if case .agentBuilderSummary = $0 { return true } else { return false } }
        let groupIndex = result.firstIndex { item in
            guard case .messages(let group) = item else { return false }
            return group.messages.contains { $0.messageId == "please" }
        }
        #expect(cardIndex != nil && groupIndex != nil)
        if let cardIndex, let groupIndex {
            #expect(cardIndex < groupIndex)
        }
    }

    @Test("Recipient run card between same-sender messages splits the group with one Sent row")
    func runCardBetweenSameSenderMessagesKeepsSingleSentRow() {
        let now = Date()
        // No summary: the run keeps its run-anchored card (recipient view),
        // which genuinely separates the two sends -- but only the bottom
        // group may carry the Sent row.
        let messages = [
            makeMessage(id: "first", sender: currentUser, text: "First", date: now),
            makeMessage(id: "b-text", sender: currentUser, text: "Be my assistant", date: now.addingTimeInterval(10)),
            makeMessage(id: "second", sender: currentUser, text: "Second", date: now.addingTimeInterval(20)),
        ]
        let result = MessagesListProcessor.process(
            messages,
            hiddenBundleMessageIds: ["b-text"]
        )
        #expect(builderCards(from: result).count == 1)
        let g = groups(from: result)
        #expect(g.count == 2)
        let flagged = g.filter(\.isLastGroupSentByCurrentUser)
        #expect(flagged.count == 1)
        #expect(flagged.first?.messages.map(\.messageId) == ["second"])
    }
}

private func makeConnectionInvocation(
    id: String = UUID().uuidString,
    sender: ConversationMember = otherUser,
    date: Date = Date()
) -> AnyMessage {
    .message(Message(
        id: id,
        sender: sender,
        source: .incoming,
        status: .published,
        content: .connectionInvocation(summary: ConnectionEventSummary(
            text: "read calendar events",
            outcome: .success,
            icon: .calendar
        )),
        date: date,
        reactions: []
    ), .existing)
}

extension MessagesListProcessorAgentBuilderCardTests {
    @Test("An invocation row landing between the bundle's publishes keeps one card")
    func invisibleRowBetweenBundlePublishesKeepsOneCard() {
        let now = Date()
        // The bundle's attachment and prompt rows publish back to back, but a
        // connection invocation (which never renders its own row) lands
        // between them. One Make must still render one card, not an
        // attachments-only card plus a prompt-only card.
        let messages = [
            makeAttachment(id: "b-att", sender: currentUser, date: now),
            makeConnectionInvocation(id: "invoke", date: now.addingTimeInterval(1)),
            makeMessage(id: "b-text", sender: currentUser, text: "Track the fog", date: now.addingTimeInterval(2)),
        ]
        let result = MessagesListProcessor.process(
            messages,
            hiddenBundleMessageIds: ["b-att", "b-text"]
        )
        let cards = builderCards(from: result)
        #expect(cards.count == 1)
        #expect(cards.first?.prompt == "Track the fog")
        #expect(cards.first?.attachments.count == 1)
    }

    @Test("Replacing a full-bleed bundle row with the card clears the neighbor's hairline adjacency")
    func swallowedFullBleedBundleClearsStaleAdjacency() {
        let now = Date()
        // A full-bleed photo sits directly above the bundle's full-bleed
        // attachment row, so the adjacency pass marks the pair before the
        // bundle rows are replaced by the card. The photo must not keep
        // hairline padding against the card row.
        let messages = [
            makeAttachment(id: "photo", sender: otherUser, date: now),
            makeAttachment(id: "b-att", sender: currentUser, date: now.addingTimeInterval(5)),
            makeMessage(id: "b-text", sender: currentUser, text: "Track the fog", date: now.addingTimeInterval(6)),
        ]
        let result = MessagesListProcessor.process(
            messages,
            hiddenBundleMessageIds: ["b-att", "b-text"]
        )
        #expect(builderCards(from: result).count == 1)
        let photoGroup = groups(from: result).first { group in
            group.messages.contains { $0.messageId == "photo" }
        }
        #expect(photoGroup != nil)
        #expect(photoGroup?.adjacentToFullBleedBelow == false)
    }
}
