import Foundation

public final class MessagesListProcessor: Sendable {
    private static let hourInSeconds: TimeInterval = 3600

    public static func process(
        _ messages: [AnyMessage],
        voiceMemoTranscripts: [String: VoiceMemoTranscriptListItem] = [:],
        readReceipts: [ReadReceiptEntry] = [],
        memberProfiles: [String: MemberProfileInfo] = [:],
        currentOtherMemberCount: Int = 0,
        sendReadReceipts: Bool = true,
        previousReadByMembers: [ConversationMember] = []
    ) -> [MessagesListItemType] {
        return processMessages(
            messages,
            voiceMemoTranscripts: voiceMemoTranscripts,
            readReceipts: readReceipts,
            memberProfiles: memberProfiles,
            currentOtherMemberCount: currentOtherMemberCount,
            sendReadReceipts: sendReadReceipts,
            previousReadByMembers: previousReadByMembers
        )
    }

    // swiftlint:disable:next cyclomatic_complexity function_body_length
    private static func processMessages(
        _ messages: [AnyMessage],
        voiceMemoTranscripts: [String: VoiceMemoTranscriptListItem] = [:],
        readReceipts: [ReadReceiptEntry] = [],
        memberProfiles: [String: MemberProfileInfo] = [:],
        currentOtherMemberCount: Int = 0,
        sendReadReceipts: Bool = true,
        previousReadByMembers: [ConversationMember] = []
    ) -> [MessagesListItemType] {
        guard !messages.isEmpty else { return [] }

        let messageCount = messages.count

        var lastAssistantJoinIndex: Int?
        var agentJoinedAfterAssistantRequest = false
        var trackedMemberCount: Int = currentOtherMemberCount

        for i in 0..<messageCount {
            let content = messages[i].content
            switch content {
            case .assistantJoinRequest:
                lastAssistantJoinIndex = i
                agentJoinedAfterAssistantRequest = false
            case .update(let update):
                if lastAssistantJoinIndex != nil, update.addedVerifiedAssistant {
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

        var currentGroupMessages: [AnyMessage] = []
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
                if !currentGroupMessages.isEmpty, currentSenderId != nil {
                    flush(
                        &items, currentGroupMessages,
                        false, false, &lastCUGroupIdx, trackedMemberCount, &lastOVIdx,
                        voiceMemoTranscripts
                    )
                    currentGroupMessages.removeAll(keepingCapacity: true)
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

                if !currentGroupMessages.isEmpty, currentSenderId != nil {
                    flush(
                        &items, currentGroupMessages,
                        false, false, &lastCUGroupIdx, trackedMemberCount, &lastOVIdx,
                        voiceMemoTranscripts
                    )
                    currentGroupMessages.removeAll(keepingCapacity: true)
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
                    if !currentGroupMessages.isEmpty, currentSenderId != nil {
                        flush(
                            &items, currentGroupMessages,
                            false, false, &lastCUGroupIdx, trackedMemberCount, &lastOVIdx,
                            voiceMemoTranscripts
                        )
                        currentGroupMessages.removeAll(keepingCapacity: true)
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

            let isFullBleedAttachment = content.isFullBleedAttachment
            let senderId = msg.senderId

            if addedDateSeparator {
                currentGroupMessages = [msg]
                currentSenderId = senderId
            } else if isFullBleedAttachment {
                if !currentGroupMessages.isEmpty, currentSenderId != nil {
                    flush(
                        &items, currentGroupMessages,
                        false, false, &lastCUGroupIdx, trackedMemberCount, &lastOVIdx,
                        voiceMemoTranscripts
                    )
                }
                flush(
                    &items, [msg],
                    false, false, &lastCUGroupIdx, trackedMemberCount, &lastOVIdx,
                    voiceMemoTranscripts
                )
                currentGroupMessages.removeAll(keepingCapacity: true)
                currentSenderId = nil
            } else if let currentId = currentSenderId, currentId != senderId {
                flush(
                    &items, currentGroupMessages,
                    false, false, &lastCUGroupIdx, trackedMemberCount, &lastOVIdx,
                    voiceMemoTranscripts
                )
                currentGroupMessages = [msg]
                currentSenderId = senderId
            } else if lastWasAttachment, currentSenderId != nil {
                flush(
                    &items, currentGroupMessages,
                    false, false, &lastCUGroupIdx, trackedMemberCount, &lastOVIdx,
                    voiceMemoTranscripts
                )
                currentGroupMessages = [msg]
                currentSenderId = senderId
            } else {
                currentGroupMessages.append(msg)
                currentSenderId = senderId
            }

            lastMessageDate = messageDate
            lastWasAttachment = isFullBleedAttachment
        }

        if !currentGroupMessages.isEmpty, currentSenderId != nil {
            let isCU = currentGroupMessages[0].senderIsCurrentUser
            flush(
                &items, currentGroupMessages,
                true, isCU, &lastCUGroupIdx, trackedMemberCount, &lastOVIdx,
                voiceMemoTranscripts
            )
        }

        if let lcui = lastCUGroupIdx, case .messages(var group) = items[lcui] {
            group.isLastGroupSentByCurrentUser = true

            if let lastMsg = group.messages.last,
               lastMsg.status == .published,
               !readReceipts.isEmpty,
               sendReadReceipts {
                let msgDateNs = Int64(lastMsg.date.timeIntervalSince1970 * 1_000_000_000)
                let senderInboxId = group.sender.profile.inboxId
                let currentReaderInboxIds = Set(
                    readReceipts
                        .filter { $0.readAtNs >= msgDateNs && $0.inboxId != senderInboxId }
                        .map(\.inboxId)
                )

                let resolveMember: (String) -> ConversationMember? = { inboxId in
                    if let member = messages.lazy
                        .compactMap({ $0.sender.profile.inboxId == inboxId ? $0.sender : nil })
                        .first {
                        return member
                    }
                    if let info = memberProfiles[inboxId] {
                        let profile = Profile(
                            inboxId: info.inboxId,
                            conversationId: info.conversationId,
                            name: info.name,
                            avatar: info.avatar
                        )
                        return ConversationMember(
                            profile: profile,
                            role: .member,
                            isCurrentUser: false
                        )
                    }
                    return nil
                }

                if !currentReaderInboxIds.isEmpty {
                    let keptInboxIds = previousReadByMembers
                        .map(\.profile.inboxId)
                        .filter { currentReaderInboxIds.contains($0) }
                    let kept = keptInboxIds.compactMap(resolveMember)
                    let keptIds = Set(kept.map(\.profile.inboxId))
                    let newInboxIds = currentReaderInboxIds.subtracting(keptIds)
                        .sorted { lhs, rhs in
                            let lhsNs = readReceipts.first { $0.inboxId == lhs }?.readAtNs ?? 0
                            let rhsNs = readReceipts.first { $0.inboxId == rhs }?.readAtNs ?? 0
                            return lhsNs != rhsNs ? lhsNs > rhsNs : lhs < rhs
                        }
                    let newMembers = newInboxIds.compactMap(resolveMember)
                    let members: [ConversationMember] = kept + newMembers
                    group = MessagesGroup(
                        id: group.id,
                        sender: group.sender,
                        messages: group.rawMessages,
                        isLastGroup: group.isLastGroup,
                        isLastGroupSentByCurrentUser: true,
                        showsTypingIndicator: group.showsTypingIndicator,
                        allTypingMembers: group.allTypingMembers,
                        readByMembers: members,
                        onlyVisibleToSender: group.onlyVisibleToSender,
                        isLastGroupBeforeOtherMembers: group.isLastGroupBeforeOtherMembers,
                        voiceMemoTranscripts: group.voiceMemoTranscripts
                    )
                }
            }

            items[lcui] = .messages(group)
        }

        if let idx = lastOVIdx, case .messages(var group) = items[idx] {
            group.isLastGroupBeforeOtherMembers = true
            items[idx] = .messages(group)
        }

        for i in 0..<items.count {
            guard items[i].isFullBleedAttachmentGroup else { continue }
            if i > 0, items[i - 1].isFullBleedAttachmentGroup {
                if case .messages(var group) = items[i] {
                    group.adjacentToFullBleedAbove = true
                    items[i] = .messages(group)
                }
            }
            if i < items.count - 1, items[i + 1].isFullBleedAttachmentGroup {
                if case .messages(var group) = items[i] {
                    group.adjacentToFullBleedBelow = true
                    items[i] = .messages(group)
                }
            }
        }

        return items
    }

    @inline(__always)
    // swiftlint:disable:next function_parameter_count
    private static func flush(
        _ items: inout [MessagesListItemType],
        _ messages: [AnyMessage],
        _ isLastGroup: Bool,
        _ isLastGroupSentByCurrentUser: Bool,
        _ lastCurrentUserIndex: inout Int?,
        _ memberCount: Int,
        _ lastOnlyVisibleIndex: inout Int?,
        _ voiceMemoTranscripts: [String: VoiceMemoTranscriptListItem] = [:]
    ) {
        guard let startMsg = messages.first else { return }
        let sender = startMsg.sender

        var groupTranscripts: [String: VoiceMemoTranscriptListItem] = [:]
        if !voiceMemoTranscripts.isEmpty {
            for message in messages {
                let messageId = message.messageId
                if let transcript = voiceMemoTranscripts[messageId] {
                    groupTranscripts[messageId] = transcript
                }
            }
        }

        var group = MessagesGroup(
            id: "group-" + startMsg.messageId,
            sender: sender,
            messages: messages,
            isLastGroup: isLastGroup,
            isLastGroupSentByCurrentUser: isLastGroupSentByCurrentUser,
            voiceMemoTranscripts: groupTranscripts
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
