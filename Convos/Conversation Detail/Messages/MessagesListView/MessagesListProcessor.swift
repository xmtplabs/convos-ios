import ConvosCore
import Foundation

/// Transforms an array of `AnyMessage` into an array of `MessagesListItemType` for display in SwiftUI
@MainActor
final class MessagesListProcessor {
    // MARK: - Constants
    private static let hourInSeconds: TimeInterval = 3600

    // MARK: - Public Methods

    /// Transforms messages into display items for the messages list
    /// - Parameter messages: Array of messages from the repository (already sorted by sortId)
    /// - Returns: Array of items ready for display in the messages list
    static func process(
        _ messages: [AnyMessage],
        readReceipts: [ReadReceiptEntry] = [],
        memberProfiles: [String: MemberProfileInfo] = [:],
        currentOtherMemberCount: Int = 0,
        sendReadReceipts: Bool = true
    ) -> [MessagesListItemType] {
        let visibleMessages = messages.filter { $0.base.content.showsInMessagesList }
        return processMessages(
            visibleMessages,
            readReceipts: readReceipts,
            memberProfiles: memberProfiles,
            currentOtherMemberCount: currentOtherMemberCount,
            sendReadReceipts: sendReadReceipts
        )
    }

    static func processWithPagination(
        _ messages: [AnyMessage],
        isLoadingPrevious: Bool = false,
        readReceipts: [ReadReceiptEntry] = [],
        memberProfiles: [String: MemberProfileInfo] = [:],
        currentOtherMemberCount: Int = 0,
        sendReadReceipts: Bool = true
    ) -> [MessagesListItemType] {
        return process(
            messages,
            readReceipts: readReceipts,
            memberProfiles: memberProfiles,
            currentOtherMemberCount: currentOtherMemberCount,
            sendReadReceipts: sendReadReceipts
        )
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

    // swiftlint:disable:next function_body_length cyclomatic_complexity
    private static func processMessages(
        _ messages: [AnyMessage],
        readReceipts: [ReadReceiptEntry] = [],
        memberProfiles: [String: MemberProfileInfo] = [:],
        currentOtherMemberCount: Int = 0,
        sendReadReceipts: Bool = true
    ) -> [MessagesListItemType] {
        guard !messages.isEmpty else { return [] }

        let lastAssistantJoinIndex: Int? = {
            guard let index = messages.lastIndex(where: { $0.base.content.isAssistantJoinRequest }) else { return nil }
            let agentJoinedAfter = messages[index...].contains(where: {
                if case .update(let update) = $0.base.content { return update.addedAgent }
                return false
            })
            return agentJoinedAfter ? nil : index
        }()

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

            if case .assistantJoinRequest(let status, _) = message.base.content {
                lastMessageDate = message.base.date
                guard index == lastAssistantJoinIndex else { continue }
                let age = Date().timeIntervalSince(message.base.date)
                guard age <= status.displayDuration else { continue }

                if !currentGroup.isEmpty, let senderId = currentSenderId {
                    flushGroup(currentGroup, senderId: senderId, items: &items, lastCurrentUserIndex: &lastMessageGroupSentByCurrentUserIndex)
                    currentGroup = []
                    currentSenderId = nil
                }
                let requesterName: String? = message.base.sender.isCurrentUser
                    ? nil
                    : message.base.sender.profile.displayName
                items.append(.assistantJoinStatus(status, requesterName: requesterName, date: message.base.date))
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
            } else if let currentId = currentSenderId, !currentGroup.isEmpty, currentGroup.last?.base.content.isAttachment == true {
                // Flush the attachment group before starting a new group
                flushGroup(currentGroup, senderId: currentId, items: &items, lastCurrentUserIndex: &lastMessageGroupSentByCurrentUserIndex)
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

        if let lastCurrentUserIndex = lastMessageGroupSentByCurrentUserIndex,
           case .messages(let group) = items[lastCurrentUserIndex] {
            var readByProfiles: [Profile] = []
            if let lastMessage = group.messages.last,
               lastMessage.base.status == .published,
               !readReceipts.isEmpty,
               sendReadReceipts {
                let messageDateNs = Int64(lastMessage.base.date.timeIntervalSince1970 * 1_000_000_000)
                let currentInboxId = group.sender.profile.inboxId
                let readInboxIds = Set(
                    readReceipts
                        .filter { $0.readAtNs >= messageDateNs && $0.inboxId != currentInboxId }
                        .map(\.inboxId)
                )
                readByProfiles = readInboxIds.compactMap { inboxId in
                    if let msgProfile = messages.lazy
                        .compactMap({ $0.base.sender.profile.inboxId == inboxId ? $0.base.sender.profile : nil })
                        .first {
                        return msgProfile
                    }
                    if let memberInfo = memberProfiles[inboxId] {
                        return Profile(inboxId: inboxId, name: memberInfo.name, avatar: memberInfo.avatar)
                    }
                    return nil
                }
            }
            var updatedGroup = MessagesGroup(
                id: group.id,
                sender: group.sender,
                messages: group.messages,
                isLastGroup: group.isLastGroup,
                isLastGroupSentByCurrentUser: true,
                readByProfiles: readByProfiles
            )
            items[lastCurrentUserIndex] = .messages(updatedGroup)
        }

        markOnlyVisibleToSender(&items, currentOtherMemberCount: currentOtherMemberCount)

        return items
    }

    private static func markOnlyVisibleToSender(
        _ items: inout [MessagesListItemType],
        currentOtherMemberCount: Int = 0
    ) {
        var otherMemberCount: Int = currentOtherMemberCount
        var lastOnlyVisibleIndex: Int?

        for i in items.indices {
            switch items[i] {
            case .update(_, let update, _):
                let addedOthers = update.addedMembers.filter { !$0.isCurrentUser }.count
                let removedOthers = update.removedMembers.filter { !$0.isCurrentUser }.count
                otherMemberCount += addedOthers
                otherMemberCount -= removedOthers
                otherMemberCount = max(0, otherMemberCount)
            case .messages(var group):
                guard group.sender.isCurrentUser else { continue }
                if otherMemberCount == 0 {
                    group.onlyVisibleToSender = true
                    items[i] = .messages(group)
                    lastOnlyVisibleIndex = i
                }
            default:
                break
            }
        }

        if let idx = lastOnlyVisibleIndex, case .messages(var group) = items[idx] {
            group.isLastGroupBeforeOtherMembers = true
            items[idx] = .messages(group)
        }
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

        // With sortId-based ordering, we keep all messages together in insertion order
        // The sorting by status is no longer needed
        let group = MessagesGroup(
            id: "group-\(firstMessage.base.id)",
            sender: firstMessage.base.sender,
            messages: messages,
            isLastGroup: isLastGroup,
            isLastGroupSentByCurrentUser: isLastGroupSentByCurrentUser
        )

        return .messages(group)
    }
}
