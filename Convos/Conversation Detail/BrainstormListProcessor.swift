import ConvosCore
import Foundation

/// Builds the `[MessagesListItemType]` snapshot rendered inside
/// `BrainstormPageView`'s `MessagesViewController`. Parallels
/// `ThinkingDetailListProcessor`, but instead of one session it interleaves,
/// in chronological order (newest at the bottom):
///
/// - every thinking session the agent has recorded in this conversation,
///   each preceded by the message it was "attached" to (the session's
///   `targetMessageId`), rendered in the regular chat-bubble style
/// - every brainstorm message in the agent's thread (the user's and the
///   agent's replies), rendered in the thought-bubble style; the current
///   user's messages sit on the trailing edge with the outgoing bubble color
enum BrainstormListProcessor {
    static func process(
        agent: ConversationMember,
        sessions: [ThinkingSessionRecord],
        brainstormMessages: [BrainstormMessageRecord],
        chatItems: [MessagesListItemType],
        members: [ConversationMember]
    ) -> [MessagesListItemType] {
        let chatMessagesById: [String: AnyMessage] = messagesById(from: chatItems)

        var entries: [(sortNs: Int64, items: [MessagesListItemType])] = []

        let agentSessions = sessions.filter { $0.senderInboxId == agent.profile.inboxId }
        for session in agentSessions {
            var items: [MessagesListItemType] = []
            if let target = chatMessagesById[session.targetMessageId] {
                items.append(targetItem(for: target, sessionId: session.id))
            }
            if let momentsGroup = momentsGroup(for: session, agent: agent) {
                items.append(momentsGroup)
            }
            if !items.isEmpty {
                entries.append((sortNs: session.startedAtNs, items: items))
            }
        }

        let agentMessages = brainstormMessages.filter { $0.agentInboxId == agent.profile.inboxId }
        for record in agentMessages {
            guard let item = brainstormMessageGroup(for: record, members: members) else { continue }
            entries.append((sortNs: record.sentAtNs, items: [item]))
        }

        let sorted = entries.sorted { $0.sortNs < $1.sortNs }
        return sorted.flatMap(\.items)
    }

    /// The chat message a thinking session was attached to, rendered in the
    /// agent-builder summary card style (bordered quote box + sender footer)
    /// so it reads as quoted chat context rather than a live thread message.
    /// Non-text targets (attachments, invites) fall back to the regular chat
    /// bubble, which can render any content type.
    private static func targetItem(for target: AnyMessage, sessionId: String) -> MessagesListItemType {
        if case .text(let text) = target.content {
            let sender = target.sender
            let footer: String = sender.isCurrentUser
                ? "Sent by you in the chat"
                : "Sent by \(sender.displayName) in the chat"
            return .agentBuilderSummary(AgentBuilderCardContent(
                id: "brainstorm-target-\(sessionId)",
                prompt: text,
                creatorIsCurrentUser: sender.isCurrentUser,
                creatorDisplayName: sender.displayName,
                creatorProfile: sender.profile,
                promptHeaderOverride: "",
                footerTextOverride: footer
            ))
        }
        var group = MessagesGroup(
            id: "brainstorm-target-\(sessionId)",
            sender: target.sender,
            messages: [target],
            isLastGroup: false,
            isLastGroupSentByCurrentUser: false
        )
        group.hidesSenderLabel = target.sender.isCurrentUser
        return .messages(group)
    }

    private static func messagesById(from items: [MessagesListItemType]) -> [String: AnyMessage] {
        var result: [String: AnyMessage] = [:]
        for item in items {
            guard case .messages(let group) = item else { continue }
            for message in group.allMessages {
                result[message.messageId] = message
            }
        }
        return result
    }

    /// One thought-bubble group per session holding every `start` moment,
    /// mirroring `ThinkingDetailListProcessor` (trailing pulsing bubble
    /// while the session is active).
    private static func momentsGroup(
        for session: ThinkingSessionRecord,
        agent: ConversationMember
    ) -> MessagesListItemType? {
        let starts = session.moments.filter { $0.state == .start }
        let showsBubble: Bool = session.isActive
        guard !starts.isEmpty || showsBubble else { return nil }

        let messages: [AnyMessage] = starts.map { (moment: ThinkingMoment) -> AnyMessage in
            let message = Message(
                id: moment.id,
                sender: agent,
                source: .incoming,
                status: .published,
                content: .text(moment.content),
                date: moment.sentAt,
                reactions: []
            )
            return .message(message, .existing)
        }

        var group = MessagesGroup(
            id: "brainstorm-session-\(session.id)",
            sender: agent,
            messages: messages,
            isLastGroup: false,
            isLastGroupSentByCurrentUser: false
        )
        group.hidesSenderLabel = true
        group.showsThinkingIndicator = showsBubble
        group.usesThoughtBubbleStyle = true
        return .messages(group)
    }

    private static func brainstormMessageGroup(
        for record: BrainstormMessageRecord,
        members: [ConversationMember]
    ) -> MessagesListItemType? {
        guard let sender = members.first(where: { $0.profile.inboxId == record.senderInboxId }) else {
            return nil
        }
        let source: MessageSource = sender.isCurrentUser ? .outgoing : .incoming
        let message = Message(
            id: record.id,
            sender: sender,
            source: source,
            status: record.status,
            content: .text(record.text),
            date: record.sentAt,
            reactions: []
        )
        var group = MessagesGroup(
            id: "brainstorm-message-\(record.clientMessageId)",
            sender: sender,
            messages: [AnyMessage.message(message, .existing)],
            isLastGroup: false,
            isLastGroupSentByCurrentUser: false
        )
        group.hidesSenderLabel = true
        group.usesThoughtBubbleStyle = true
        return .messages(group)
    }
}
