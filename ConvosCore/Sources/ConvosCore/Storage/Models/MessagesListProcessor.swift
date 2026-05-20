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
        previousReadByMembers: [ConversationMember] = [],
        verifiedAssistant: ConversationMember? = nil,
        assistantBuilderSummary: AssistantBuilderSummary? = nil
    ) -> [MessagesListItemType] {
        let baseItems: [MessagesListItemType] = processMessages(
            messages,
            voiceMemoTranscripts: voiceMemoTranscripts,
            readReceipts: readReceipts,
            memberProfiles: memberProfiles,
            currentOtherMemberCount: currentOtherMemberCount,
            sendReadReceipts: sendReadReceipts,
            previousReadByMembers: previousReadByMembers,
            verifiedAssistant: verifiedAssistant
        )
        return applyAssistantContactCardAndSummary(
            to: baseItems,
            verifiedAssistant: verifiedAssistant,
            assistantBuilderSummary: assistantBuilderSummary
        )
    }

    /// Post-process the raw item list to (a) cut messages predating the
    /// `AssistantBuilderSummary.cutoffDate`, (b) attach the contact-card prefix
    /// to the assistant's first messages group (synthesizing an empty group
    /// when the assistant hasn't said anything yet), and (c) prepend the
    /// summary cell.
    private static func applyAssistantContactCardAndSummary(
        to baseItems: [MessagesListItemType],
        verifiedAssistant: ConversationMember?,
        assistantBuilderSummary: AssistantBuilderSummary?
    ) -> [MessagesListItemType] {
        var items: [MessagesListItemType] = baseItems

        if let summary = assistantBuilderSummary {
            items = items.flatMap { item -> [MessagesListItemType] in
                switch item {
                case .messages(let group):
                    if group.sender.isCurrentUser {
                        // User-side: filter by `bundledMessageIds`. The set
                        // is populated synchronously in
                        // `AssistantBuilderViewModel.commit()` before the
                        // writer is called, so the prompt text + multi-remote
                        // bundle are caught the instant they appear in the
                        // DB. Messages the user types after Make (not in the
                        // set) flow through normally. A group can contain
                        // both — consecutive same-sender messages stay in
                        // one group regardless of the gap.
                        let kept: [AnyMessage] = group.messages.filter {
                            !summary.bundledMessageIds.contains($0.messageId)
                        }
                        if kept.isEmpty { return [] }
                        if kept.count == group.messages.count { return [item] }
                        var rebuilt: MessagesGroup = MessagesGroup(
                            id: group.id,
                            sender: group.sender,
                            messages: kept,
                            isLastGroup: group.isLastGroup,
                            isLastGroupSentByCurrentUser: group.isLastGroupSentByCurrentUser,
                            showsTypingIndicator: group.showsTypingIndicator,
                            allTypingMembers: group.allTypingMembers,
                            readByMembers: group.readByMembers,
                            onlyVisibleToSender: group.onlyVisibleToSender,
                            isLastGroupBeforeOtherMembers: group.isLastGroupBeforeOtherMembers,
                            voiceMemoTranscripts: group.voiceMemoTranscripts
                        )
                        rebuilt.adjacentToFullBleedAbove = group.adjacentToFullBleedAbove
                        rebuilt.adjacentToFullBleedBelow = group.adjacentToFullBleedBelow
                        rebuilt.assistantContactCard = group.assistantContactCard
                        return [.messages(rebuilt)]
                    } else {
                        // Assistant / other-member groups: filter by the
                        // group's latest message, no pad. Pre-Make hello
                        // messages drop wholesale; later replies stay.
                        let date: Date = group.messages.last?.date ?? group.messages.first?.date ?? .distantPast
                        return date >= summary.cutoffDate ? [item] : []
                    }
                case .assistantJoinStatus:
                    // The summary card already announces the assistant's
                    // arrival; suppress the transient "Assistant is joining…"
                    // pending row so they don't compete.
                    return []
                default:
                    return [item]
                }
            }
            // Drop date separators that no longer precede a visible message
            // group. The base processor emits a `.date(...)` row before the
            // first message of a new calendar window, but if every message
            // in that window was a builder-bundle send (just filtered
            // above), the separator is now orphaned and flashes briefly
            // post-Make while the agent provisions.
            items = dropOrphanDateSeparators(in: items)
        }

        if let assistant = verifiedAssistant {
            let cardInfo = AssistantContactCardInfo(
                profile: assistant.profile,
                jobSummary: assistant.profile.jobSummary
            )
            let firstAssistantGroupIndex: Int? = items.firstIndex { item in
                guard case .messages(let group) = item else { return false }
                return group.sender.profile.inboxId == assistant.profile.inboxId
            }
            if let idx = firstAssistantGroupIndex, case .messages(var group) = items[idx] {
                group.assistantContactCard = cardInfo
                items[idx] = .messages(group)
            } else {
                var cardGroup = MessagesGroup(
                    id: "assistant-contact-card-\(assistant.profile.inboxId)",
                    sender: assistant,
                    messages: [],
                    isLastGroup: false,
                    isLastGroupSentByCurrentUser: false
                )
                cardGroup.assistantContactCard = cardInfo
                items.insert(.messages(cardGroup), at: 0)
            }
        }

        if let summary = assistantBuilderSummary {
            items.insert(.assistantBuilderSummary(summary), at: 0)
        }

        return items
    }

    /// Strip date separators that no longer precede a message group. A
    /// `.date(...)` row is kept iff there is at least one `.messages(...)`
    /// row before the next `.date(...)` (or end of list). All other item
    /// kinds (typing indicator, system updates, etc.) don't anchor a date
    /// — they share the most recent group's bucket.
    private static func dropOrphanDateSeparators(in items: [MessagesListItemType]) -> [MessagesListItemType] {
        var result: [MessagesListItemType] = []
        result.reserveCapacity(items.count)
        for (index, item) in items.enumerated() {
            if case .date = item {
                var hasFollowingGroup: Bool = false
                for later in items[(index + 1)...] {
                    if case .date = later { break }
                    if case .messages = later {
                        hasFollowingGroup = true
                        break
                    }
                }
                if !hasFollowingGroup { continue }
            }
            result.append(item)
        }
        return result
    }

    // swiftlint:disable:next cyclomatic_complexity function_body_length
    private static func processMessages(
        _ messages: [AnyMessage],
        voiceMemoTranscripts: [String: VoiceMemoTranscriptListItem] = [:],
        readReceipts: [ReadReceiptEntry] = [],
        memberProfiles: [String: MemberProfileInfo] = [:],
        currentOtherMemberCount: Int = 0,
        sendReadReceipts: Bool = true,
        previousReadByMembers: [ConversationMember] = [],
        verifiedAssistant: ConversationMember? = nil
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
                // The "Assistant joined · see its skills" affordance has been
                // replaced by the assistant contact card; suppress the legacy
                // update bubble so the two don't compete in the list.
                if !update.addedVerifiedAssistant {
                    items.append(.update(id: msg.messageId, update: update, origin: msg.origin))
                }

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

            if case .connectionEvent(let eventSummary) = content {
                lastMessageDate = msg.date
                if !currentGroupMessages.isEmpty, currentSenderId != nil {
                    flush(
                        &items, currentGroupMessages,
                        false, false, &lastCUGroupIdx, trackedMemberCount, &lastOVIdx,
                        voiceMemoTranscripts
                    )
                    currentGroupMessages.removeAll(keepingCapacity: true)
                    currentSenderId = nil
                }
                let resolvedSummary = resolvingActor(in: eventSummary, sender: msg.sender, memberProfiles: memberProfiles)
                items.append(.connectionEvent(id: msg.messageId, summary: resolvedSummary, origin: msg.origin))
                lastWasAttachment = false
                continue
            }

            if case .connectionInvocationResult(let resultSummary) = content {
                lastMessageDate = msg.date
                if !currentGroupMessages.isEmpty, currentSenderId != nil {
                    flush(
                        &items, currentGroupMessages,
                        false, false, &lastCUGroupIdx, trackedMemberCount, &lastOVIdx,
                        voiceMemoTranscripts
                    )
                    currentGroupMessages.removeAll(keepingCapacity: true)
                    currentSenderId = nil
                }
                let resolvedSummary = resolvingActor(in: resultSummary, sender: msg.sender, memberProfiles: memberProfiles)
                items.append(.connectionEvent(id: msg.messageId, summary: resolvedSummary, origin: msg.origin))
                lastWasAttachment = false
                continue
            }

            if case .connectionInvocation = content {
                lastMessageDate = msg.date
                lastWasAttachment = false
                continue
            }

            if case .connectionPayload(let payloadSummary) = content {
                lastMessageDate = msg.date
                if !currentGroupMessages.isEmpty, currentSenderId != nil {
                    flush(
                        &items, currentGroupMessages,
                        false, false, &lastCUGroupIdx, trackedMemberCount, &lastOVIdx,
                        voiceMemoTranscripts
                    )
                    currentGroupMessages.removeAll(keepingCapacity: true)
                    currentSenderId = nil
                }
                let resolvedSummary = resolvingActor(in: payloadSummary, sender: msg.sender, memberProfiles: memberProfiles)
                items.append(.connectionEvent(id: msg.messageId, summary: resolvedSummary, origin: msg.origin))
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

    /// Materialize the actor for a `ConnectionEventSummary` whose `text` is an
    /// actor-less phrase.
    ///
    /// - `.messageSender` is resolved using the message's own sender snapshot. That
    ///   snapshot is per-message and stable.
    /// - `.grantedAgent` is resolved by inbox-id-keyed lookup against `memberProfiles`.
    ///   The lookup is by stable inbox id (not the verification flag), so it doesn't
    ///   flap during attestation re-verification; ProfileUpdates that rename the agent
    ///   trigger a `memberProfiles` change which re-runs the processor and re-bakes the
    ///   text — same path `.messageSender` uses.
    /// - `nil` actor (no actor expected) is returned unchanged.
    private static func resolvingActor(
        in summary: ConnectionEventSummary,
        sender: ConversationMember,
        memberProfiles: [String: MemberProfileInfo]
    ) -> ConnectionEventSummary {
        let actorName: String
        switch summary.actor {
        case .messageSender:
            actorName = sender.isCurrentUser ? "You" : sender.profile.displayName
        case .grantedAgent:
            guard let inboxId = summary.grantedToInboxId,
                  let name = memberProfiles[inboxId]?.name,
                  !name.isEmpty else {
                return summary
            }
            actorName = name
        case .none:
            return summary
        }
        guard !actorName.isEmpty else { return summary }
        return ConnectionEventSummary(
            text: "\(actorName) \(summary.text)",
            outcome: summary.outcome,
            icon: summary.icon,
            actor: summary.actor,
            grantedToInboxId: summary.grantedToInboxId
        )
    }
}
