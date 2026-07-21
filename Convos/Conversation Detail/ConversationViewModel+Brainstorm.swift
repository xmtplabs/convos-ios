import ConvosCore
import Foundation

/// Brainstorm: a per-agent side thread built from the agent's thinking
/// history plus standard replies chained onto it. Outgoing brainstorm
/// messages reply to the agent's most recent thinking message; when the
/// agent has never thought, a silent brainstorm anchor is published first
/// and the reply references that. Either way the reference id points at a
/// row outside the chat table, which is what keeps brainstorm messages out
/// of the main messages list (see `MessagesRepository`).
extension ConversationViewModel {
    /// Agent members that get a brainstorm page in the conversation pager,
    /// in roster order.
    var brainstormAgents: [ConversationMember] {
        conversation.members.filter(\.isAgent)
    }

    func brainstormAgent(inboxId: String) -> ConversationMember? {
        conversation.members.first { $0.profile.inboxId == inboxId }
    }

    /// Snapshot for one agent's brainstorm page: thinking sessions (with
    /// their target messages) interleaved chronologically with the thread's
    /// brainstorm messages.
    func brainstormItems(for agentInboxId: String) -> [MessagesListItemType] {
        guard let agent = brainstormAgent(inboxId: agentInboxId) else { return [] }
        return BrainstormListProcessor.process(
            agent: agent,
            sessions: thinkingSessions,
            brainstormMessages: brainstormFeed.messages,
            chatItems: messages,
            members: conversation.members
        )
    }

    func hasBrainstormContent(for agentInboxId: String) -> Bool {
        let hasSessions = thinkingSessions.contains { $0.senderInboxId == agentInboxId }
        let hasMessages = brainstormFeed.messages.contains { $0.agentInboxId == agentInboxId }
        return hasSessions || hasMessages
    }

    func sendBrainstormMessage(text: String, toAgentInboxId agentInboxId: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        let messageWriter = cachedMessageWriter
        let existingReferenceId = brainstormReferenceId(for: agentInboxId)
        Task {
            do {
                let referenceId: String
                if let existingReferenceId {
                    referenceId = existingReferenceId
                } else {
                    referenceId = try await messageWriter.sendBrainstormAnchor(agentInboxId: agentInboxId)
                }
                try await messageWriter.sendBrainstormReply(text: trimmed, toReferenceId: referenceId)
            } catch {
                Log.error("Failed to send brainstorm message: \(error)")
            }
        }
    }

    /// The reply-chain reference for a new brainstorm message: the agent's
    /// most recent thinking message, falling back to the newest anchor
    /// already opened for this agent. Nil means the sender must publish an
    /// anchor first.
    private func brainstormReferenceId(for agentInboxId: String) -> String? {
        let latestMoment: ThinkingMoment? = thinkingSessions
            .filter { $0.senderInboxId == agentInboxId }
            .flatMap(\.moments)
            .max { $0.sentAtNs < $1.sentAtNs }
        if let latestMoment {
            return latestMoment.id
        }
        return brainstormFeed.anchors.last { $0.agentInboxId == agentInboxId }?.id
    }
}
