import Foundation

/// Client flow for starting (or resuming) a private DM with an agent that is
/// already a member of one of the user's conversations. The DM is a standard
/// 2-member conversation carrying the agent-DM custom-metadata marker; the
/// agent side accepts or leaves based on its own policy. See
/// docs/plans/agent-dms.md.
public enum AgentDmFlow {
    /// Lookup-first: reuse an existing 1:1 with the agent, otherwise create a
    /// conversation, stamp the agent-DM marker, and add the agent's inbox.
    /// Returns the conversation id to navigate to.
    public static func startOrFindDm(
        agentInboxId: String,
        originConversationId: String?,
        session: any SessionManagerProtocol
    ) async throws -> String {
        if let existing = try? session
            .conversationsRepository(for: [.allowed, .unknown])
            .findAgentDm(with: agentInboxId) {
            return existing.id
        }

        let stateManager = session.messagingService().conversationStateManager()
        try await stateManager.createConversation(startsUnused: false)
        let conversationId = try await AgentCreationFlow.awaitReadyConversationId(stateManager: stateManager)
        let metadataWriter = stateManager.conversationMetadataWriter
        // Stamp the marker before the agent lands so every welcome observer
        // (our own devices included) classifies the conversation correctly.
        try await metadataWriter.markAsAgentDm(conversationId, originConversationId: originConversationId)
        try await metadataWriter.addMembers([agentInboxId], to: conversationId)
        // The creation pipeline's own metadata writers (invite tag, emoji)
        // race the marker's read-modify-write and can rewrite appData without
        // it. Re-stamp after the add so the on-wire state settles with the
        // marker; the local row is additionally latched by the writer.
        try await metadataWriter.markAsAgentDm(conversationId, originConversationId: originConversationId)
        return conversationId
    }
}
