import ConvosCore
import Foundation

struct YourSpaceUpdate: Identifiable, Equatable {
    let conversation: Conversation
    let conversationTitle: String
    let personName: String?
    let detail: String
    let date: Date
    let needsAttention: Bool

    var id: String { conversation.id }

    var shareText: String {
        if let personName {
            return "\(personName) in \(conversationTitle): \(detail)"
        }
        return "\(conversationTitle): \(detail)"
    }
}

struct YourSpaceBriefing: Equatable {
    let headline: String
    let attentionUpdates: [YourSpaceUpdate]
    let recentUpdates: [YourSpaceUpdate]
    let sourceCount: Int
    let peopleCount: Int

    var attentionCount: Int { attentionUpdates.count }
}

enum YourSpaceBriefingBuilder {
    static func make(
        conversations: [Conversation],
        memberNameOverride: (String) -> String? = { _ in nil }
    ) -> YourSpaceBriefing {
        let visibleConversations = conversations
            .sorted { activityDate(for: $0) > activityDate(for: $1) }
        let updates = visibleConversations.compactMap {
            makeUpdate(for: $0, memberNameOverride: memberNameOverride)
        }
        let attention = updates.filter(\.needsAttention)

        return YourSpaceBriefing(
            headline: headline(
                sourceCount: visibleConversations.count,
                attentionUpdates: attention
            ),
            attentionUpdates: attention,
            recentUpdates: Array(updates.prefix(8)),
            sourceCount: visibleConversations.count,
            peopleCount: peopleCount(in: visibleConversations)
        )
    }

    private static func makeUpdate(
        for conversation: Conversation,
        memberNameOverride: (String) -> String?
    ) -> YourSpaceUpdate? {
        let title = conversation.computedDisplayName(memberNameOverride: memberNameOverride)

        if conversation.isPendingInvite {
            return YourSpaceUpdate(
                conversation: conversation,
                conversationTitle: title,
                personName: nil,
                detail: "Your invite is still being verified.",
                date: conversation.createdAt,
                needsAttention: true
            )
        }

        guard let preview = latestPreview(for: conversation) else { return nil }

        return YourSpaceUpdate(
            conversation: conversation,
            conversationTitle: title,
            // MessagePreview does not currently expose sender metadata. Never
            // infer identity from message text; richer person attribution can
            // be added once the repository supplies a verified sender.
            personName: nil,
            detail: previewDetail(preview.text),
            date: preview.createdAt,
            needsAttention: conversation.isUnread || conversation.agentDm?.isUnread == true
        )
    }

    private static func latestPreview(for conversation: Conversation) -> MessagePreview? {
        switch (conversation.lastMessage, conversation.agentDm?.lastMessage) {
        case let (group?, agent?):
            return group.createdAt >= agent.createdAt ? group : agent
        case let (group?, nil):
            return group
        case let (nil, agent?):
            return agent
        case (nil, nil):
            return nil
        }
    }

    private static func activityDate(for conversation: Conversation) -> Date {
        latestPreview(for: conversation)?.createdAt ?? conversation.createdAt
    }

    private static func previewDetail(_ rawText: String) -> String {
        let trimmed = rawText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return "Shared a new update."
        }
        return clipped(trimmed)
    }

    private static func clipped(_ value: String) -> String {
        let limit = 180
        guard value.count > limit else { return value }
        return String(value.prefix(limit)).trimmingCharacters(in: .whitespacesAndNewlines) + "…"
    }

    private static func headline(sourceCount: Int, attentionUpdates: [YourSpaceUpdate]) -> String {
        guard sourceCount > 0 else {
            return "Your private space is ready. Start a convo and the context will grow with you."
        }

        guard let first = attentionUpdates.first else {
            let noun = sourceCount == 1 ? "convo" : "convos"
            return "Nothing needs you right now. Your Space is quietly keeping up with \(sourceCount) \(noun)."
        }

        guard let second = attentionUpdates.dropFirst().first else {
            return headlineClause(for: first)
        }

        let remaining = attentionUpdates.count - 2
        let ending = remaining > 0
            ? " \(remaining) more \(remaining == 1 ? "convo has" : "convos have") new context."
            : ""
        return headlineClause(for: first) + " "
            + headlineClause(for: second)
            + ending
    }

    private static func headlineClause(for update: YourSpaceUpdate) -> String {
        if let personName = update.personName {
            return "\(personName) shared something new in \(update.conversationTitle)."
        }
        return "\(update.conversationTitle) has new context."
    }

    private static func peopleCount(in conversations: [Conversation]) -> Int {
        Set(conversations.flatMap(\.membersWithoutCurrent).map(\.profile.inboxId)).count
    }
}
