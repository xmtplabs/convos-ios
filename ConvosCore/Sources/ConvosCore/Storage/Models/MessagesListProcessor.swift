import Foundation

public final class MessagesListProcessor: Sendable {
    private static let hourInSeconds: TimeInterval = 3600
    /// Long same-sender runs split into display groups of at most this many
    /// messages so a single collection cell never builds and measures dozens
    /// of bubbles at once (the dominant cost when opening a conversation).
    /// Continuation chunks render seamlessly via `continuesPreviousGroup` /
    /// `isContinuedBelow`.
    private static let maxMessagesPerDisplayGroup: Int = 10

    public static func process(
        _ messages: [AnyMessage],
        voiceMemoTranscripts: [String: VoiceMemoTranscriptListItem] = [:],
        readReceipts: [ReadReceiptEntry] = [],
        memberProfiles: [String: MemberProfileInfo] = [:],
        currentOtherMemberCount: Int = 0,
        sendReadReceipts: Bool = true,
        previousReadByMembers: [ConversationMember] = [],
        verifiedAgent: ConversationMember? = nil,
        agentBuilderSummary: AgentBuilderSummary? = nil,
        hiddenBundleMessageIds: Set<String> = [],
        isInAgentBuilderFlow: Bool = false
    ) -> [MessagesListItemType] {
        let baseItems: [MessagesListItemType] = processMessages(
            messages,
            voiceMemoTranscripts: voiceMemoTranscripts,
            readReceipts: readReceipts,
            memberProfiles: memberProfiles,
            currentOtherMemberCount: currentOtherMemberCount,
            sendReadReceipts: sendReadReceipts,
            previousReadByMembers: previousReadByMembers,
            verifiedAgent: verifiedAgent
        )
        // The "build" is the prompt + attachment messages the builder sent on
        // the user's behalf. Their ids reach the processor two ways: the
        // networked `BuilderBundleManifest` populates `hiddenBundleMessageIds`
        // on every member's client, and the creator's local `AgentBuilderSummary`
        // carries `bundledMessageIds`. Union them -- on the sender the prompt
        // renders under its client UUID (only in `bundledMessageIds`); on
        // recipients it renders under its XMTP id (only in
        // `hiddenBundleMessageIds`). The processor rebuilds the summary card from
        // these messages and positions it where they landed, instead of dropping
        // them silently or rendering them as bare bubbles.
        let buildMessageIds: Set<String> = hiddenBundleMessageIds
            .union(agentBuilderSummary?.bundledMessageIds ?? [])
        return applyAgentBuilderCardsAndContactCard(
            to: baseItems,
            rawMessages: messages,
            buildMessageIds: buildMessageIds,
            verifiedAgent: verifiedAgent,
            agentBuilderSummary: agentBuilderSummary,
            isInAgentBuilderFlow: isInAgentBuilderFlow
        )
    }

    /// Rebuild a `MessagesGroup` with a new id + message subset, copying the
    /// presentation side-channel fields the initializer doesn't take.
    private static func rebuiltGroup(_ group: MessagesGroup, id: String, messages: [AnyMessage]) -> MessagesGroup {
        var rebuilt: MessagesGroup = MessagesGroup(
            id: id,
            sender: group.sender,
            messages: messages,
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
        rebuilt.agentContactCard = group.agentContactCard
        rebuilt.thinkingByMessageId = group.thinkingByMessageId
        rebuilt.hidesSenderLabel = group.hidesSenderLabel
        rebuilt.continuesPreviousGroup = group.continuesPreviousGroup
        rebuilt.isContinuedBelow = group.isContinuedBelow
        rebuilt.showsThinkingIndicator = group.showsThinkingIndicator
        rebuilt.thinkingContent = group.thinkingContent
        rebuilt.usesThoughtBubbleStyle = group.usesThoughtBubbleStyle
        rebuilt.contactCardThinkingDescriptor = group.contactCardThinkingDescriptor
        rebuilt.contactCardPrecedesAgentMessages = group.contactCardPrecedesAgentMessages
        return rebuilt
    }

    /// Group build messages into runs of entries adjacent in the message stream.
    /// One Make sends its prompt + attachment bundle back to back, so they form a
    /// single run (and a single card); separate Make events split by other
    /// messages form separate runs and render separate cards.
    private static func buildRuns(in rawMessages: [AnyMessage], buildMessageIds: Set<String>) -> [[AnyMessage]] {
        guard !buildMessageIds.isEmpty else { return [] }
        var runs: [[AnyMessage]] = []
        var current: [AnyMessage] = []
        var lastIndex: Int?
        for (index, message) in rawMessages.enumerated() where buildMessageIds.contains(message.messageId) {
            if let last = lastIndex, index == last + 1 {
                current.append(message)
            } else {
                if !current.isEmpty { runs.append(current) }
                current = [message]
            }
            lastIndex = index
        }
        if !current.isEmpty { runs.append(current) }
        return runs
    }

    /// The `AgentBuilderConnection` raw values captured in a creator's local
    /// summary, used for the connection chips. Empty for recipients (no summary).
    private static func builderConnectionIdentifiers(from summary: AgentBuilderSummary) -> [String] {
        summary.attachments.compactMap { attachment in
            if case .connection(_, let identifier) = attachment { return identifier }
            return nil
        }
    }

    /// Assemble the card render model for one build run: prompt from the run's
    /// text message, chips from its attachment message. Connection chips + the
    /// morph flag come from the creator's local `summary` (nil on recipients).
    private static func makeCardContent(
        run: [AnyMessage],
        anchor: String,
        summary: AgentBuilderSummary?
    ) -> AgentBuilderCardContent {
        var prompt: String = ""
        var attachments: [HydratedAttachment] = []
        for message in run {
            switch message.content {
            case .text(let text):
                if prompt.isEmpty { prompt = text }
            case .attachment(let attachment):
                attachments.append(attachment)
            case .attachments(let bundled):
                attachments.append(contentsOf: bundled)
            default:
                break
            }
        }
        // The build messages are sent on the user's behalf, so their sender is
        // the agent's creator. Use it for the footer attribution now that the
        // card renders for every member.
        let creator: ConversationMember? = run.first?.sender
        let connectionIdentifiers: [String] = summary.map(builderConnectionIdentifiers(from:)) ?? []
        let existingConversation: Bool = summary?.existingConversation ?? false
        let transitionEligible: Bool = summary != nil && !existingConversation
        return AgentBuilderCardContent(
            id: "agent-builder-card-" + anchor,
            prompt: prompt,
            attachments: attachments,
            creatorIsCurrentUser: creator?.isCurrentUser ?? true,
            creatorDisplayName: creator?.profile.displayName ?? "",
            connectionIdentifiers: connectionIdentifiers,
            existingConversation: existingConversation,
            transitionEligible: transitionEligible
        )
    }

    /// Rebuild the agent-builder summary card(s) from the build's own messages
    /// (`buildMessageIds`) and splice each in at the position those messages
    /// occupied, dropping the raw build bubbles. Adjacent build messages (the
    /// attachment bundle + the prompt text) collapse into a single card.
    private static func reconstructBuilderCards(
        in items: [MessagesListItemType],
        rawMessages: [AnyMessage],
        buildMessageIds: Set<String>,
        agentBuilderSummary: AgentBuilderSummary?
    ) -> [MessagesListItemType] {
        let runs: [[AnyMessage]] = buildRuns(in: rawMessages, buildMessageIds: buildMessageIds)
        guard !runs.isEmpty else { return items }

        let summaryIds: Set<String> = Set(agentBuilderSummary?.bundledMessageIds ?? [])
        var anchorByMessageId: [String: String] = [:]
        var cardByAnchor: [String: AgentBuilderCardContent] = [:]
        for run in runs {
            guard let anchor = run.first?.messageId else { continue }
            for message in run { anchorByMessageId[message.messageId] = anchor }
            let ownsSummary: Bool = !summaryIds.isEmpty && run.contains { summaryIds.contains($0.messageId) }
            cardByAnchor[anchor] = makeCardContent(
                run: run,
                anchor: anchor,
                summary: ownsSummary ? agentBuilderSummary : nil
            )
        }

        var result: [MessagesListItemType] = []
        result.reserveCapacity(items.count)
        var emittedAnchors: Set<String> = []

        for item in items {
            guard case .messages(let group) = item,
                  group.messages.contains(where: { buildMessageIds.contains($0.messageId) }) else {
                result.append(item)
                continue
            }
            // Walk the group, splitting it into build vs non-build segments.
            // Build segments collapse into their run's card (emitted once);
            // non-build segments stay as their own group with a stable id.
            var segment: [AnyMessage] = []
            var segmentIsBuild: Bool = false
            func flushSegment() {
                guard let first = segment.first else { return }
                if segmentIsBuild {
                    if let anchor = anchorByMessageId[first.messageId],
                       !emittedAnchors.contains(anchor),
                       let card = cardByAnchor[anchor] {
                        emittedAnchors.insert(anchor)
                        result.append(.agentBuilderSummary(card))
                    }
                } else {
                    result.append(.messages(rebuiltGroup(group, id: "group-" + first.messageId, messages: segment)))
                }
                segment = []
            }
            for message in group.messages {
                let isBuild: Bool = buildMessageIds.contains(message.messageId)
                if !segment.isEmpty, isBuild != segmentIsBuild { flushSegment() }
                segmentIsBuild = isBuild
                segment.append(message)
            }
            flushSegment()
        }
        return result
    }

    /// Rebuild the agent-builder summary card(s) from the build messages and
    /// position them chronologically, then attach the agent contact card.
    /// Replaces the old index-0 pinning of a local-only summary: the card is now
    /// rebuilt from the prompt + attachment messages every member receives, so it
    /// is visible to everyone and sits where Make happened.
    private static func applyAgentBuilderCardsAndContactCard(
        to baseItems: [MessagesListItemType],
        rawMessages: [AnyMessage],
        buildMessageIds: Set<String>,
        verifiedAgent: ConversationMember?,
        agentBuilderSummary: AgentBuilderSummary?,
        isInAgentBuilderFlow: Bool
    ) -> [MessagesListItemType] {
        var items: [MessagesListItemType] = baseItems

        // Suppress the legacy "Agent joined" update row while the builder UI is
        // on screen (home flow): pre-Make it sits under the builder overlay, and
        // during the post-Make morph the summary + contact card already announce
        // arrival, so the row would only flash through the fade-out. Recipients
        // and the dismissed existing-conversation builder are never
        // `isInAgentBuilderFlow`, so they keep the join row as a real event and
        // as the contact-card anchor. Gates on `addedAgent` (not
        // `addedVerifiedAgent`): attestation lands after the member-added event,
        // and the flash window is before verification completes.
        if isInAgentBuilderFlow {
            items = items.filter { item in
                guard case .update(_, let update, _) = item else { return true }
                return !update.addedAgent
            }
        }

        if !buildMessageIds.isEmpty {
            items = reconstructBuilderCards(
                in: items,
                rawMessages: rawMessages,
                buildMessageIds: buildMessageIds,
                agentBuilderSummary: agentBuilderSummary
            )
            // Splicing out the build bubbles can orphan the date separator that
            // preceded them; the card now anchors that day, so re-run the sweep
            // (the card counts as an anchor) to keep a valid separator and drop a
            // truly empty one.
            items = dropOrphanDateSeparators(in: items)
        }

        if let agent = verifiedAgent {
            items = insertingContactCard(in: items, agent: agent)
        }

        return items
    }

    /// Strip date separators that no longer precede a message group. A
    /// `.date(...)` row is kept iff there is at least one anchorable row
    /// (`.messages`, `.update`, `.connectionEvent`, or `.agentBuilderSummary`)
    /// before the next `.date(...)` (or end of list). Typing indicators, info
    /// rows, and other purely ephemeral items don't anchor — a stretch with only
    /// those leaves the date separator orphaned and it is dropped.
    private static func dropOrphanDateSeparators(in items: [MessagesListItemType]) -> [MessagesListItemType] {
        var result: [MessagesListItemType] = []
        result.reserveCapacity(items.count)
        for (index, item) in items.enumerated() {
            if case .date = item {
                var hasFollowingAnchor: Bool = false
                for later in items[(index + 1)...] {
                    if case .date = later { break }
                    switch later {
                    case .messages, .update, .connectionEvent, .agentBuilderSummary:
                        hasFollowingAnchor = true
                    default:
                        break
                    }
                    if hasFollowingAnchor { break }
                }
                if !hasFollowingAnchor { continue }
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
        verifiedAgent: ConversationMember? = nil
    ) -> [MessagesListItemType] {
        guard !messages.isEmpty else { return [] }

        let messageCount = messages.count

        var lastAgentJoinIndex: Int?
        var agentJoinedAfterAgentRequest = false
        var trackedMemberCount: Int = currentOtherMemberCount

        for i in 0..<messageCount {
            let content = messages[i].content
            switch content {
            case .assistantJoinRequest:
                lastAgentJoinIndex = i
                agentJoinedAfterAgentRequest = false
            case .update(let update):
                if lastAgentJoinIndex != nil, update.addedAgent {
                    agentJoinedAfterAgentRequest = true
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

        if agentJoinedAfterAgentRequest {
            lastAgentJoinIndex = nil
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
                // Always emit verified-agent join updates; the post-process
                // step in `applyAgentBuilderCardsAndContactCard` suppresses them
                // for builder-flow conversations (where the summary card and
                // contact card both already announce arrival) and uses them
                // as the anchor for the synthesized contact-card row in
                // every other conversation.
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
                guard index == lastAgentJoinIndex else { continue }
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
                    .agentJoinStatus(status, requesterName: requesterName, date: msg.date)
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
                    let continuesPrevious = group.continuesPreviousGroup
                    let continuedBelow = group.isContinuedBelow
                    let hidesLabel = group.hidesSenderLabel
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
                    group.continuesPreviousGroup = continuesPrevious
                    group.isContinuedBelow = continuedBelow
                    group.hidesSenderLabel = hidesLabel
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

private extension MessagesListProcessor {
    /// Insert the agent contact card as its own standalone row. The card has
    /// a single placement rule, so it never relocates as the agent's
    /// messages, connection events, or user replies stream in around it.
    /// Anchor chain: right after the last builder summary card (the summary
    /// always sits above the card -- in the home flow the agent joins before
    /// the Make bundle, so anchoring on the join row there would put the
    /// card first); else right after the agent-join update row (non-builder
    /// agent conversations); else right before the agent's first message
    /// group (join row outside the loaded window); else the top of the list.
    static func insertingContactCard(
        in baseItems: [MessagesListItemType],
        agent: ConversationMember
    ) -> [MessagesListItemType] {
        var items: [MessagesListItemType] = baseItems
        var cardGroup = MessagesGroup(
            id: "agent-contact-card-\(agent.profile.inboxId)",
            sender: agent,
            messages: [],
            isLastGroup: false,
            isLastGroupSentByCurrentUser: false
        )
        cardGroup.agentContactCard = AgentContactCardInfo(
            profile: agent.profile,
            agentDescription: agent.profile.agentDescription
        )
        let builderCardIndex: Int? = items.lastIndex { item in
            if case .agentBuilderSummary = item { return true }
            return false
        }
        let joinUpdateIndex: Int? = items.firstIndex { item in
            guard case .update(_, let update, _) = item else { return false }
            return update.addedVerifiedAgent
        }
        let firstAgentGroupIndex: Int? = items.firstIndex { item in
            guard case .messages(let group) = item else { return false }
            return group.sender.profile.inboxId == agent.profile.inboxId
        }
        let insertionIndex: Int = builderCardIndex.map { $0 + 1 }
            ?? joinUpdateIndex.map { $0 + 1 }
            ?? firstAgentGroupIndex
            ?? 0
        // When the agent's own messages sit directly below the card, the
        // pair renders as one visual run: the card keeps the sender label,
        // the group below drops its duplicate label, and the leading avatar
        // attaches to that group's last message instead of the card.
        if insertionIndex < items.count,
           case .messages(var below) = items[insertionIndex],
           below.sender.profile.inboxId == agent.profile.inboxId {
            below.hidesSenderLabel = true
            items[insertionIndex] = .messages(below)
            cardGroup.contactCardPrecedesAgentMessages = true
        }
        items.insert(.messages(cardGroup), at: insertionIndex)
        return items
    }

    @inline(__always)
    // swiftlint:disable:next function_parameter_count
    static func flush(
        _ items: inout [MessagesListItemType],
        _ messages: [AnyMessage],
        _ isLastGroup: Bool,
        _ isLastGroupSentByCurrentUser: Bool,
        _ lastCurrentUserIndex: inout Int?,
        _ memberCount: Int,
        _ lastOnlyVisibleIndex: inout Int?,
        _ voiceMemoTranscripts: [String: VoiceMemoTranscriptListItem] = [:]
    ) {
        guard !messages.isEmpty else { return }
        let sender = messages[0].sender

        var chunks: [[AnyMessage]] = []
        var index = 0
        while index < messages.count {
            let end = min(index + maxMessagesPerDisplayGroup, messages.count)
            chunks.append(Array(messages[index..<end]))
            index = end
        }

        for (chunkIndex, chunk) in chunks.enumerated() {
            guard let startMsg = chunk.first else { continue }
            let isFinalChunk = chunkIndex == chunks.count - 1

            var groupTranscripts: [String: VoiceMemoTranscriptListItem] = [:]
            if !voiceMemoTranscripts.isEmpty {
                for message in chunk {
                    let messageId = message.messageId
                    if let transcript = voiceMemoTranscripts[messageId] {
                        groupTranscripts[messageId] = transcript
                    }
                }
            }

            var group = MessagesGroup(
                id: "group-" + startMsg.messageId,
                sender: sender,
                messages: chunk,
                isLastGroup: isFinalChunk && isLastGroup,
                isLastGroupSentByCurrentUser: isFinalChunk && isLastGroupSentByCurrentUser,
                voiceMemoTranscripts: groupTranscripts
            )
            if chunkIndex > 0 {
                group.continuesPreviousGroup = true
                group.hidesSenderLabel = true
            }
            group.isContinuedBelow = !isFinalChunk

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
}
