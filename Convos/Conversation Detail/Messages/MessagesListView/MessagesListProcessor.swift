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

    // swiftlint:disable:next cyclomatic_complexity
    private static func processMessages(_ messages: [AnyMessage]) -> [MessagesListItemType] {
        guard !messages.isEmpty else { return [] }

        var items: [MessagesListItemType] = []
        var currentGroup: [AnyMessage] = []
        var currentSenderId: String?
        var lastMessageDate: Date?
        var lastMessageGroupSentByCurrentUserIndex: Int?

        for (index, message) in messages.enumerated() {
            // Check if this is an update message
            if case .update(let update) = message.base.content {
                // Flush current group if exists
                if !currentGroup.isEmpty, let senderId = currentSenderId {
                    let group = createMessageGroup(
                        messages: currentGroup,
                        senderId: senderId,
                        isLastGroup: false,
                        isLastGroupSentByCurrentUser: false
                    )
                    items.append(group)

                    // Track if this was sent by current user
                    if case .messages(let messagesGroup) = group, messagesGroup.sender.isCurrentUser {
                        lastMessageGroupSentByCurrentUserIndex = items.count - 1
                    }

                    currentGroup = []
                    currentSenderId = nil
                }

                // Add the update item with the message's origin
                items.append(.update(id: message.base.id, update: update, origin: message.origin))
                lastMessageDate = message.base.date
                continue
            }

            // Check if we need a date separator
            var addedDateSeparator = false
            if let lastDate = lastMessageDate {
                let timeDifference = message.base.date.timeIntervalSince(lastDate)
                if timeDifference > hourInSeconds {
                    // Flush current group before adding date separator
                    if !currentGroup.isEmpty, let senderId = currentSenderId {
                        let group = createMessageGroup(
                            messages: currentGroup,
                            senderId: senderId,
                            isLastGroup: false,
                            isLastGroupSentByCurrentUser: false
                        )
                        items.append(group)

                        // Track if this was sent by current user
                        if case .messages(let messagesGroup) = group, messagesGroup.sender.isCurrentUser {
                            lastMessageGroupSentByCurrentUserIndex = items.count - 1
                        }

                        currentGroup = []
                        currentSenderId = nil
                    }

                    items.append(.date(DateGroup(date: message.base.date)))
                    addedDateSeparator = true
                }
            } else if index == 0 {
                // Add date for the first message
                items.append(.date(DateGroup(date: message.base.date)))
                addedDateSeparator = true
            }

            // Group messages by sender
            // If we added a date separator, always start a new group
            // Otherwise, only start a new group if the sender changed
            if addedDateSeparator {
                // Always start a new group after a date separator
                currentGroup = [message]
                currentSenderId = message.base.sender.id
            } else if let currentId = currentSenderId, currentId != message.base.sender.id {
                // Sender changed, flush the current group
                let group = createMessageGroup(
                    messages: currentGroup,
                    senderId: currentId,
                    isLastGroup: false,
                    isLastGroupSentByCurrentUser: false
                )
                items.append(group)

                // Track if this was sent by current user
                if case .messages(let messagesGroup) = group, messagesGroup.sender.isCurrentUser {
                    lastMessageGroupSentByCurrentUserIndex = items.count - 1
                }

                currentGroup = [message]
                currentSenderId = message.base.sender.id
            } else {
                // Same sender and no date separator, continue the group
                currentGroup.append(message)
                currentSenderId = message.base.sender.id
            }

            lastMessageDate = message.base.date
        }

        // Flush the last group - we know this is the last message group
        if !currentGroup.isEmpty, let senderId = currentSenderId {
            guard let firstMessage = currentGroup.first else {
                fatalError("Cannot create message group with empty messages array")
            }

            let isCurrentUser = firstMessage.base.sender.isCurrentUser
            let isLastGroupByCurrentUser = isCurrentUser

            items.append(createMessageGroup(
                messages: currentGroup,
                senderId: senderId,
                isLastGroup: true,
                isLastGroupSentByCurrentUser: isLastGroupByCurrentUser
            ))

            // If this is sent by current user, update our tracking
            if isCurrentUser {
                lastMessageGroupSentByCurrentUserIndex = items.count - 1
            }
        }

        // Now update the last group sent by current user flag if it's not the last group overall
        if let lastCurrentUserIndex = lastMessageGroupSentByCurrentUserIndex {
            // Find the actual last message group index
            var lastMessageGroupIndex: Int?
            for (index, item) in items.enumerated().reversed() {
                if case .messages = item {
                    lastMessageGroupIndex = index
                    break
                }
            }

            // If the last current user group is not the last overall group, update its flag
            if lastCurrentUserIndex != lastMessageGroupIndex,
               case .messages(let group) = items[lastCurrentUserIndex] {
                let updatedGroup = MessagesGroup(
                    id: group.id,
                    sender: group.sender,
                    messages: group.messages,
                    unpublished: group.unpublished,
                    isLastGroup: false,
                    isLastGroupSentByCurrentUser: true
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
