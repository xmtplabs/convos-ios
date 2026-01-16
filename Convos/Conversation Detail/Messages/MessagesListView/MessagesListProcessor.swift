import ConvosCore
import Foundation

/// Transforms an array of `AnyMessage` into an array of `MessagesListItemType` for display in SwiftUI
@MainActor
final class MessagesListProcessor {
    // MARK: - Constants
    private static let hourInSeconds: TimeInterval = 3600

    // MARK: - Public Methods

    /// Transforms messages into display items for the messages list
    /// - Parameter messages: Array of messages from the repository
    /// - Returns: Array of items ready for display in the messages list
    static func process(_ messages: [AnyMessage]) -> [MessagesListItemType] {
        // 1. Filter out messages that shouldn't be shown
        let visibleMessages = messages.filter { $0.base.content.showsInMessagesList }

        // 2. Sort messages by date (they should already be sorted, but ensure it)
        let sortedMessages = visibleMessages.sorted { $0.base.date < $1.base.date }

        // 3. Process all messages together, keeping unpublished messages in their groups
        return processMessages(sortedMessages)
    }

    /// Processes messages for pagination scenarios
    /// When loading previous messages, this method ensures proper grouping and date handling
    /// - Parameters:
    ///   - messages: Array of all messages from the repository (including newly loaded)
    ///   - isLoadingPrevious: Whether we're loading previous messages (affects date separator logic)
    /// - Returns: Array of items ready for display in the messages list
    static func processWithPagination(_ messages: [AnyMessage], isLoadingPrevious: Bool = false) -> [MessagesListItemType] {
        // Use the standard process method - it handles all messages properly
        // The repository already ensures messages are in the correct order
        return process(messages)
    }

    // MARK: - Private Methods

    private static func flushGroup(
        _ group: [AnyMessage],
        senderId: String,
        items: inout [MessagesListItemType],
        lastCurrentUserIndex: inout Int?
    ) {
        let newGroup = createMessageGroup(messages: group, senderId: senderId, isLastGroup: false, isLastGroupSentByCurrentUser: false)
        items.append(newGroup)
        if case .messages(let messagesGroup) = newGroup, messagesGroup.sender.isCurrentUser {
            lastCurrentUserIndex = items.count - 1
        }
    }

    // swiftlint:disable:next cyclomatic_complexity
    private static func processMessages(_ messages: [AnyMessage]) -> [MessagesListItemType] {
        guard !messages.isEmpty else { return [] }

        var items: [MessagesListItemType] = []
        var currentGroup: [AnyMessage] = []
        var currentSenderId: String?
        var lastMessageDate: Date?
        var lastMessageGroupSentByCurrentUserIndex: Int?

        for (index, message) in messages.enumerated() {
            if case .update(let update) = message.base.content {
                if !currentGroup.isEmpty, let senderId = currentSenderId {
                    flushGroup(currentGroup, senderId: senderId, items: &items, lastCurrentUserIndex: &lastMessageGroupSentByCurrentUserIndex)
                    currentGroup = []
                    currentSenderId = nil
                }
                items.append(.update(id: message.base.id, update: update, origin: message.origin))
                lastMessageDate = message.base.date
                continue
            }

            var addedDateSeparator = false
            if let lastDate = lastMessageDate {
                let timeDifference = message.base.date.timeIntervalSince(lastDate)
                if timeDifference > hourInSeconds {
                    if !currentGroup.isEmpty, let senderId = currentSenderId {
                        flushGroup(currentGroup, senderId: senderId, items: &items, lastCurrentUserIndex: &lastMessageGroupSentByCurrentUserIndex)
                        currentGroup = []
                        currentSenderId = nil
                    }
                    items.append(.date(DateGroup(date: message.base.date)))
                    addedDateSeparator = true
                }
            } else if index == 0 {
                items.append(.date(DateGroup(date: message.base.date)))
                addedDateSeparator = true
            }

            let isAttachment = message.base.content.isAttachment

            if addedDateSeparator {
                currentGroup = [message]
                currentSenderId = message.base.sender.id
            } else if isAttachment {
                if !currentGroup.isEmpty, let currentId = currentSenderId {
                    flushGroup(currentGroup, senderId: currentId, items: &items, lastCurrentUserIndex: &lastMessageGroupSentByCurrentUserIndex)
                }
                flushGroup([message], senderId: message.base.sender.id, items: &items, lastCurrentUserIndex: &lastMessageGroupSentByCurrentUserIndex)
                currentGroup = []
                currentSenderId = nil
            } else if let currentId = currentSenderId, currentId != message.base.sender.id {
                flushGroup(currentGroup, senderId: currentId, items: &items, lastCurrentUserIndex: &lastMessageGroupSentByCurrentUserIndex)
                currentGroup = [message]
                currentSenderId = message.base.sender.id
            } else if !currentGroup.isEmpty && currentGroup.last?.base.content.isAttachment == true {
                currentGroup = [message]
                currentSenderId = message.base.sender.id
            } else {
                currentGroup.append(message)
                currentSenderId = message.base.sender.id
            }

            lastMessageDate = message.base.date
        }

        if !currentGroup.isEmpty, let senderId = currentSenderId {
            guard let firstMessage = currentGroup.first else {
                fatalError("Cannot create message group with empty messages array")
            }
            let isCurrentUser = firstMessage.base.sender.isCurrentUser
            items.append(createMessageGroup(messages: currentGroup, senderId: senderId, isLastGroup: true, isLastGroupSentByCurrentUser: isCurrentUser))
            if isCurrentUser { lastMessageGroupSentByCurrentUserIndex = items.count - 1 }
        }

        if let lastCurrentUserIndex = lastMessageGroupSentByCurrentUserIndex {
            var lastMessageGroupIndex: Int?
            for (idx, item) in items.enumerated().reversed() where lastMessageGroupIndex == nil {
                if case .messages = item { lastMessageGroupIndex = idx }
            }
            if lastCurrentUserIndex != lastMessageGroupIndex, case .messages(let group) = items[lastCurrentUserIndex] {
                let updatedGroup = MessagesGroup(
                    id: group.id, sender: group.sender, messages: group.messages, unpublished: group.unpublished,
                    isLastGroup: false, isLastGroupSentByCurrentUser: true
                )
                items[lastCurrentUserIndex] = .messages(updatedGroup)
            }
        }

        return items
    }

    private static func createMessageGroup(
        messages: [AnyMessage],
        senderId: String,
        isLastGroup: Bool,
        isLastGroupSentByCurrentUser: Bool
    ) -> MessagesListItemType {
        guard let firstMessage = messages.first else {
            fatalError("Cannot create message group with empty messages array")
        }

        // Separate published and unpublished messages
        let published = messages.filter { $0.base.status == .published }
        let unpublished = messages.filter { $0.base.status != .published }

        let group = MessagesGroup(
            id: "group-\(firstMessage.base.id)",
            sender: firstMessage.base.sender,
            messages: published,
            unpublished: unpublished,
            isLastGroup: isLastGroup,
            isLastGroupSentByCurrentUser: isLastGroupSentByCurrentUser
        )

        return .messages(group)
    }
}
