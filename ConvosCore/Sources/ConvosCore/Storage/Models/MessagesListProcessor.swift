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

    /// Group build messages into runs. One Make sends its prompt + attachment
    /// bundle back to back, so they form a single run (and a single card);
    /// separate Make events split by other visible messages form separate runs
    /// and render separate cards. Rows that never render their own list item
    /// (silent updates, connection invocations) don't break a run -- one
    /// landing between the bundle's publishes must not turn one Make into two
    /// cards.
    private static func buildRuns(in rawMessages: [AnyMessage], buildMessageIds: Set<String>) -> [[AnyMessage]] {
        guard !buildMessageIds.isEmpty else { return [] }
        var runs: [[AnyMessage]] = []
        var current: [AnyMessage] = []
        var visibleRowSinceLastBuildRow: Bool = false
        for message in rawMessages {
            if buildMessageIds.contains(message.messageId) {
                if visibleRowSinceLastBuildRow, !current.isEmpty {
                    runs.append(current)
                    current = []
                }
                current.append(message)
                visibleRowSinceLastBuildRow = false
            } else if rendersOwnListRow(message.content) {
                visibleRowSinceLastBuildRow = true
            }
        }
        if !current.isEmpty { runs.append(current) }
        return runs
    }

    /// Whether a message produces its own row in the list. Mirrors the two
    /// silent paths in `processMessages`: contents hidden by
    /// `showsInMessagesList`, and connection invocations, which the grouping
    /// loop skips outright.
    private static func rendersOwnListRow(_ content: MessageContent) -> Bool {
        guard content.showsInMessagesList else { return false }
        if case .connectionInvocation = content { return false }
        return true
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
            // The creator's own latest build renders via the Make-anchored
            // summary card (see applyAgentBuilderCardsAndContactCard): its
            // position tracks when the user tapped Make, not when the held
            // bundle eventually published. Swallow those rows without
            // emitting a run card; every other build (recipients, older
            // builds whose summary was replaced) keeps its run-anchored card.
            guard !ownsSummary else { continue }
            cardByAnchor[anchor] = makeCardContent(run: run, anchor: anchor, summary: nil)
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
            // Walk the group, collapsing build rows into their run's card
            // (emitted once, where the run's first row sat); non-build
            // messages stay as their own group with a stable id. A swallowed
            // run (the creator's own latest build, which renders via the
            // Make-anchored summary card instead) leaves nothing behind, so
            // it must not split the surrounding same-sender messages into
            // two groups -- that would render two "Sent" rows.
            var segment: [AnyMessage] = []
            func flushSegment() {
                guard let first = segment.first else { return }
                result.append(.messages(rebuiltGroup(group, id: "group-" + first.messageId, messages: segment)))
                segment = []
            }
            for message in group.messages {
                guard buildMessageIds.contains(message.messageId) else {
                    segment.append(message)
                    continue
                }
                guard let anchor = anchorByMessageId[message.messageId],
                      !emittedAnchors.contains(anchor),
                      let card = cardByAnchor[anchor] else { continue }
                emittedAnchors.insert(anchor)
                flushSegment()
                result.append(.agentBuilderSummary(card))
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

        // The creator's card, anchored at the Make moment (the summary's
        // cutoffDate) rather than at the position the held bundle eventually
        // published -- messages sent while the send waited for the agent to
        // join stay below the card. The run reconstruction above swallows the
        // summary's own rows without emitting a card, so this is the sole
        // creator-side card and it never relocates when the rows land.
        // Before the rows land it renders from the summary alone, time-boxed
        // so a summary whose rows later expire (disappearing messages)
        // doesn't resurrect a card in an old chat. An empty raw snapshot of
        // an existing conversation means history hasn't loaded yet -- skip
        // that emission (the loaded one follows immediately) instead of
        // flashing the card at the top of a one-item list.
        if let summary = agentBuilderSummary {
            let summaryIds: Set<String> = summary.bundledMessageIds
            let rowsLanded: Bool = rawMessages.contains { summaryIds.contains($0.messageId) }
            let withinWindow: Bool = Date().timeIntervalSince(summary.cutoffDate) < Self.pendingCardDisplayWindow
            let awaitingHistory: Bool = rawMessages.isEmpty && summary.existingConversation
            if rowsLanded || (withinWindow && !awaitingHistory) {
                insertSummaryCard(
                    .agentBuilderSummary(makePendingCardContent(summary: summary)),
                    into: &items,
                    cutoffDate: summary.cutoffDate
                )
            }
        }

        if let agent = verifiedAgent {
            items = insertingContactCard(in: items, agent: agent)
        }

        items = reconcilingFullBleedAdjacency(in: items)
        return clearingDuplicatedLastGroupFlags(in: items)
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

            if case .capabilityConnect(let prompt) = content {
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
                let agentName = resolvedAskerName(for: prompt, sender: msg.sender, memberProfiles: memberProfiles)
                items.append(.capabilityConnect(id: msg.messageId, prompt: prompt, agentName: agentName, origin: msg.origin))
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
                            avatar: info.avatar,
                            isAgent: info.isAgent
                        )
                        return ConversationMember(
                            profile: profile,
                            role: .member,
                            isCurrentUser: false,
                            isAgent: info.isAgent,
                            agentVerification: info.agentVerification
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
            grantedToInboxId: summary.grantedToInboxId,
            providerId: summary.providerId
        )
    }

    /// Display name for the agent behind a connect prompt's "<Agent> wants to
    /// connect" caption. Prefers the live member-profile lookup by the request's
    /// `askerInboxId` (renames propagate like connection events); falls back to
    /// the message sender's snapshot, which is the asker in practice.
    private static func resolvedAskerName(
        for prompt: CapabilityConnectPrompt,
        sender: ConversationMember,
        memberProfiles: [String: MemberProfileInfo]
    ) -> String {
        if let name = memberProfiles[prompt.askerInboxId]?.name, !name.isEmpty {
            return name
        }
        return sender.profile.displayName
    }
}

private extension MessagesListProcessor {
    /// Splitting a message group (run-card splice, Make-boundary insert)
    /// copies the group's presentation flags into every half, but the
    /// "last group" flags are positional -- if more than one group carries
    /// one, each renders its own "Sent" status row. Keep each flag only on
    /// its bottom-most carrier.
    static func clearingDuplicatedLastGroupFlags(
        in baseItems: [MessagesListItemType]
    ) -> [MessagesListItemType] {
        var items: [MessagesListItemType] = baseItems
        var seenLastSentByCurrentUser: Bool = false
        var seenLastBeforeOtherMembers: Bool = false
        for index in items.indices.reversed() {
            guard case .messages(var group) = items[index] else { continue }
            var changed: Bool = false
            if group.isLastGroupSentByCurrentUser {
                if seenLastSentByCurrentUser {
                    group.isLastGroupSentByCurrentUser = false
                    changed = true
                } else {
                    seenLastSentByCurrentUser = true
                }
            }
            if group.isLastGroupBeforeOtherMembers {
                if seenLastBeforeOtherMembers {
                    group.isLastGroupBeforeOtherMembers = false
                    changed = true
                } else {
                    seenLastBeforeOtherMembers = true
                }
            }
            if changed { items[index] = .messages(group) }
        }
        return items
    }

    /// The full-bleed adjacency pass runs before the card splices, so a group
    /// can keep a flag from a full-bleed neighbor that was swallowed or
    /// replaced by a card row -- rendering hairline padding against a
    /// non-media row. Clear any flag whose neighbor is no longer a full-bleed
    /// group (clear-only: a group never gains hairline treatment here).
    static func reconcilingFullBleedAdjacency(
        in baseItems: [MessagesListItemType]
    ) -> [MessagesListItemType] {
        var items: [MessagesListItemType] = baseItems
        for index in items.indices {
            guard case .messages(var group) = items[index],
                  group.adjacentToFullBleedAbove || group.adjacentToFullBleedBelow else { continue }
            let fullBleedAbove: Bool = index > 0 && items[index - 1].isFullBleedAttachmentGroup
            let fullBleedBelow: Bool = index < items.count - 1 && items[index + 1].isFullBleedAttachmentGroup
            var changed: Bool = false
            if group.adjacentToFullBleedAbove, !fullBleedAbove {
                group.adjacentToFullBleedAbove = false
                changed = true
            }
            if group.adjacentToFullBleedBelow, !fullBleedBelow {
                group.adjacentToFullBleedBelow = false
                changed = true
            }
            if changed { items[index] = .messages(group) }
        }
        return items
    }

    /// Insert the agent contact card as its own standalone row. The card has
    /// a single placement rule, so it never relocates as the agent's
    /// messages, connection events, or user replies stream in around it.
    /// Anchor chain: right after this agent's builder summary card (the
    /// first summary between the agent's join row and the agent's first
    /// message group -- the summary always sits above the card, and later
    /// Makes add summaries further down that must not steal the card); else
    /// right after this agent's most recent join update row (non-builder
    /// agent conversations; matching on inboxId keeps the card off other or
    /// former agents' join rows, and re-adds anchor on the latest join);
    /// else right before the agent's first message group (join row outside
    /// the loaded window); else the top of the list.
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
        let joinUpdateIndex: Int? = items.lastIndex { item in
            guard case .update(_, let update, _) = item else { return false }
            return update.addedVerifiedAgent
                && update.addedMembers.contains { $0.profile.inboxId == agent.profile.inboxId }
        }
        let firstAgentGroupIndex: Int? = items.firstIndex { item in
            guard case .messages(let group) = item else { return false }
            return group.sender.profile.inboxId == agent.profile.inboxId
        }
        // This agent's Make summary lives between its join row and its first
        // message group (in the home flow the join sorts directly above the
        // summary). Bounding the search keeps the card anchored to its own
        // summary when later Makes append summaries further down the list.
        // A re-added agent's old messages can sit above its latest join row;
        // the clamp collapses the range so the card anchors on the join.
        let searchStart: Int = joinUpdateIndex ?? 0
        let searchEnd: Int = max(searchStart, firstAgentGroupIndex ?? items.count)
        let summarySearchRange: Range<Int> = searchStart..<searchEnd
        let builderCardIndex: Int? = items[summarySearchRange].firstIndex { item in
            if case .agentBuilderSummary = item { return true }
            return false
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
        // The full-bleed adjacency pass ran before the splice, so groups on
        // either side of the card may still carry flags from when they were
        // adjacent to each other. The card row is never full bleed; clear
        // the flags facing it.
        if insertionIndex > 0, case .messages(var above) = items[insertionIndex - 1] {
            above.adjacentToFullBleedBelow = false
            items[insertionIndex - 1] = .messages(above)
        }
        if insertionIndex < items.count, case .messages(var below) = items[insertionIndex] {
            below.adjacentToFullBleedAbove = false
            items[insertionIndex] = .messages(below)
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

    /// How long after Make the summary-only card may render while its build
    /// messages haven't landed. Covers the writer's agent-join hold (150s)
    /// with margin; past it, a row-less summary is history, not a pending
    /// build.
    private static let pendingCardDisplayWindow: TimeInterval = 180

    /// Insert the summary card at its chronological Make slot: right after
    /// the bottom-most message older than `cutoffDate`. Consecutive
    /// same-sender messages merge into one group, so messages sent around
    /// Make routinely share a group whose span straddles the boundary --
    /// comparing whole groups would shove the card above the entire merged
    /// group (the top of the list in a fresh chat). When the boundary falls
    /// inside a group, split it at the boundary and seat the card between
    /// the halves, the same way `reconstructBuilderCards` splices run cards
    /// into groups. Falls back to the top of the newer groups (nothing
    /// older) or the end of the list (no message groups at all).
    private static func insertSummaryCard(
        _ card: MessagesListItemType,
        into items: inout [MessagesListItemType],
        cutoffDate: Date
    ) {
        var firstNewerGroupIndex: Int = items.count
        for (index, item) in items.enumerated().reversed() {
            guard case .messages(let group) = item,
                  let firstDate = group.messages.first?.date,
                  let lastDate = group.messages.last?.date else { continue }
            if lastDate <= cutoffDate {
                items.insert(card, at: index + 1)
                return
            }
            if firstDate <= cutoffDate {
                let older: [AnyMessage] = group.messages.filter { $0.date <= cutoffDate }
                let newer: [AnyMessage] = group.messages.filter { $0.date > cutoffDate }
                guard let olderFirst = older.first, let newerFirst = newer.first else { continue }
                let olderGroup: MessagesGroup = rebuiltGroup(group, id: "group-" + olderFirst.messageId, messages: older)
                let newerGroup: MessagesGroup = rebuiltGroup(group, id: "group-" + newerFirst.messageId, messages: newer)
                items.replaceSubrange(index...index, with: [.messages(olderGroup), card, .messages(newerGroup)])
                return
            }
            firstNewerGroupIndex = index
        }
        items.insert(card, at: firstNewerGroupIndex)
    }

    /// Card content built from the summary alone, for the window between Make
    /// and the build messages landing. Mirrors `makeCardContent` with the
    /// summary's stored snapshots standing in for the not-yet-persisted
    /// messages; the anchor reuses the first bundled id so the cell identity
    /// is stable when the real run-anchored card takes over.
    private static func makePendingCardContent(summary: AgentBuilderSummary) -> AgentBuilderCardContent {
        let anchor: String = summary.bundledMessageIds.min() ?? summary.id.uuidString
        let attachments: [HydratedAttachment] = summary.attachments.compactMap { attachment in
            switch attachment {
            case let .photo(id, thumbnailData):
                return HydratedAttachment(
                    key: id.uuidString,
                    mimeType: "image/jpeg",
                    thumbnailDataBase64: thumbnailData?.base64EncodedString()
                )
            case let .video(id, thumbnailData):
                return HydratedAttachment(
                    key: id.uuidString,
                    mimeType: "video/mp4",
                    thumbnailDataBase64: thumbnailData?.base64EncodedString()
                )
            case let .file(id, filename, mimeType, fileSize):
                return HydratedAttachment(
                    key: id.uuidString,
                    mimeType: mimeType,
                    fileSize: fileSize,
                    filename: filename
                )
            case let .voiceMemo(id, duration, levels):
                return HydratedAttachment(
                    key: id.uuidString,
                    mimeType: "audio/m4a",
                    duration: duration,
                    waveformLevels: levels
                )
            case .connection:
                // Rendered via `connectionIdentifiers`, not as a media chip.
                return nil
            }
        }
        return AgentBuilderCardContent(
            id: "agent-builder-card-" + anchor,
            prompt: summary.prompt,
            attachments: attachments,
            creatorIsCurrentUser: true,
            creatorDisplayName: "",
            connectionIdentifiers: builderConnectionIdentifiers(from: summary),
            existingConversation: summary.existingConversation,
            transitionEligible: !summary.existingConversation
        )
    }
}
