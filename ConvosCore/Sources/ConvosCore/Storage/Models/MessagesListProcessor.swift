import Foundation

public final class MessagesListProcessor: Sendable {
    private static let hourInSeconds: TimeInterval = 3600

    public static func process(_ messages: [AnyMessage], otherMemberCount: Int = 0) -> [MessagesListItemType] {
        return processMessages(messages, otherMemberCount: otherMemberCount)
    }

    // swiftlint:disable:next cyclomatic_complexity function_body_length
    private static func processMessages(
        _ messages: [AnyMessage],
        otherMemberCount: Int = 0
    ) -> [MessagesListItemType] {
        guard !messages.isEmpty else { return [] }

        let messageCount = messages.count

        var lastAssistantJoinIndex: Int?
        var agentJoinedAfterAssistantRequest = false
        var trackedMemberCount: Int = otherMemberCount

        for i in 0..<messageCount {
            let content = messages[i].content
            switch content {
            case .assistantJoinRequest:
                lastAssistantJoinIndex = i
                agentJoinedAfterAssistantRequest = false
            case .update(let update):
                if lastAssistantJoinIndex != nil, update.addedAgent {
                    agentJoinedAfterAssistantRequest = true
                }
                var added = 0
                var removed = 0
                for m in update.addedMembers where !m.isCurrentUser { added += 1 }
                for m in update.removedMembers where !m.isCurrentUser { removed += 1 }
                trackedMemberCount -= added
                trackedMemberCount += removed
            default:
                break
            }
        }

        if agentJoinedAfterAssistantRequest {
            lastAssistantJoinIndex = nil
        }
        trackedMemberCount = max(0, trackedMemberCount)

        var items: [MessagesListItemType] = []
        items.reserveCapacity(messageCount)

        var groupStartIndex: Int = -1
        var groupEndIndex: Int = -1
        var currentSenderId: String?
        var lastMessageDate: Date?
        var lastCUGroupIdx: Int?
        var isFirstVisible: Bool = true
        var lastWasAttachment: Bool = false
        var lastOVIdx: Int?

        for index in 0..<messageCount {
            let msg = messages[index]
            let content = msg.content

            guard content.showsInMessagesList else { continue }

            if case .update(let update) = content {
                if groupStartIndex >= 0, currentSenderId != nil {
                    flush(
                        &items, messages, groupStartIndex, groupEndIndex,
                        false, false, &lastCUGroupIdx, trackedMemberCount, &lastOVIdx
                    )
                    groupStartIndex = -1
                    currentSenderId = nil
                }
                items.append(.update(id: msg.messageId, update: update, origin: msg.origin))

                var added = 0
                var removed = 0
                for m in update.addedMembers where !m.isCurrentUser { added += 1 }
                for m in update.removedMembers where !m.isCurrentUser { removed += 1 }
                trackedMemberCount += added
                trackedMemberCount -= removed
                trackedMemberCount = max(0, trackedMemberCount)

                lastMessageDate = msg.date
                lastWasAttachment = false
                continue
            }

            if case .assistantJoinRequest(let status, _) = content {
                lastMessageDate = msg.date
                guard index == lastAssistantJoinIndex else { continue }
                let age = Date().timeIntervalSince(msg.date)
                guard age <= status.displayDuration else { continue }

                if groupStartIndex >= 0, currentSenderId != nil {
                    flush(
                        &items, messages, groupStartIndex, groupEndIndex,
                        false, false, &lastCUGroupIdx, trackedMemberCount, &lastOVIdx
                    )
                    groupStartIndex = -1
                    currentSenderId = nil
                }
                let sender = msg.sender
                let requesterName: String? = sender.isCurrentUser
                    ? nil
                    : sender.profile.displayName
                items.append(
                    .assistantJoinStatus(status, requesterName: requesterName, date: msg.date)
                )
                lastMessageDate = msg.date
                lastWasAttachment = false
                continue
            }

            let messageDate = msg.date
            var addedDateSeparator = false
            if let lastDate = lastMessageDate {
                if messageDate.timeIntervalSince(lastDate) > hourInSeconds {
                    if groupStartIndex >= 0, currentSenderId != nil {
                        flush(
                            &items, messages, groupStartIndex, groupEndIndex,
                            false, false, &lastCUGroupIdx, trackedMemberCount, &lastOVIdx
                        )
                        groupStartIndex = -1
                        currentSenderId = nil
                    }
                    items.append(.date(DateGroup(date: messageDate)))
                    addedDateSeparator = true
                }
            } else if isFirstVisible {
                items.append(.date(DateGroup(date: messageDate)))
                addedDateSeparator = true
            }
            isFirstVisible = false

            let isAttachment = content.isAttachment
            let senderId = msg.senderId

            if addedDateSeparator {
                groupStartIndex = index
                groupEndIndex = index
                currentSenderId = senderId
            } else if isAttachment {
                if groupStartIndex >= 0, currentSenderId != nil {
                    flush(
                        &items, messages, groupStartIndex, groupEndIndex,
                        false, false, &lastCUGroupIdx, trackedMemberCount, &lastOVIdx
                    )
                }
                flush(
                    &items, messages, index, index,
                    false, false, &lastCUGroupIdx, trackedMemberCount, &lastOVIdx
                )
                groupStartIndex = -1
                currentSenderId = nil
            } else if let currentId = currentSenderId, currentId != senderId {
                flush(
                    &items, messages, groupStartIndex, groupEndIndex,
                    false, false, &lastCUGroupIdx, trackedMemberCount, &lastOVIdx
                )
                groupStartIndex = index
                groupEndIndex = index
                currentSenderId = senderId
            } else if lastWasAttachment, currentSenderId != nil {
                flush(
                    &items, messages, groupStartIndex, groupEndIndex,
                    false, false, &lastCUGroupIdx, trackedMemberCount, &lastOVIdx
                )
                groupStartIndex = index
                groupEndIndex = index
                currentSenderId = senderId
            } else {
                if groupStartIndex < 0 {
                    groupStartIndex = index
                }
                groupEndIndex = index
                currentSenderId = senderId
            }

            lastMessageDate = messageDate
            lastWasAttachment = isAttachment
        }

        if groupStartIndex >= 0, currentSenderId != nil {
            let isCU = messages[groupStartIndex].senderIsCurrentUser
            flush(
                &items, messages, groupStartIndex, groupEndIndex,
                true, isCU, &lastCUGroupIdx, trackedMemberCount, &lastOVIdx
            )
        }

        if let lcui = lastCUGroupIdx, case .messages(var group) = items[lcui] {
            group.isLastGroupSentByCurrentUser = true
            items[lcui] = .messages(group)
        }

        if let idx = lastOVIdx, case .messages(var group) = items[idx] {
            group.isLastGroupBeforeOtherMembers = true
            items[idx] = .messages(group)
        }

        return items
    }

    @inline(__always)
    // swiftlint:disable:next function_parameter_count
    private static func flush(
        _ items: inout [MessagesListItemType],
        _ messages: [AnyMessage],
        _ start: Int,
        _ end: Int,
        _ isLastGroup: Bool,
        _ isLastGroupSentByCurrentUser: Bool,
        _ lastCurrentUserIndex: inout Int?,
        _ memberCount: Int,
        _ lastOnlyVisibleIndex: inout Int?
    ) {
        let startMsg = messages[start]
        let sender = startMsg.sender
        var group = MessagesGroup(
            id: "group-" + startMsg.messageId,
            sender: sender,
            messages: messages[start...end],
            isLastGroup: isLastGroup,
            isLastGroupSentByCurrentUser: isLastGroupSentByCurrentUser
        )

        if sender.isCurrentUser {
            lastCurrentUserIndex = items.count
            if memberCount == 0 {
                group.onlyVisibleToSender = true
                lastOnlyVisibleIndex = items.count
            }
        }

        items.append(.messages(group))
    }
}
