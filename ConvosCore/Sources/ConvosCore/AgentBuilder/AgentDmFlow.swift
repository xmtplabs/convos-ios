import Foundation
import os

/// Client flow for starting (or resuming) a private DM with an agent that is
/// already a member of one of the user's conversations. The DM is a standard
/// 2-member conversation carrying the agent-DM custom-metadata marker; the
/// agent side accepts or leaves based on its own policy. See
/// docs/plans/agent-dms.md.
public enum AgentDmFlow {
    /// The create currently in flight per agent in this process. Closes the
    /// lookup-then-create race between the reconciler and the DM page's
    /// first-send path: a second caller awaits the first create's own task -
    /// however long it takes - instead of minting a duplicate or racing a
    /// poll against the create's timeout budget. (The backend's atomic
    /// per-peer reserve remains the cross-device authority; this only
    /// prevents same-process duplicates.)
    private static let inFlight: OSAllocatedUnfairLock<[String: Task<String, Error>]> = .init(initialState: [:])

    /// Lookup-first: reuse an existing 1:1 with the agent, otherwise create a
    /// conversation, stamp the agent-DM marker, and add the agent's inbox.
    /// Returns the conversation id to navigate to.
    public static func startOrFindDm(
        agentInboxId: String,
        originConversationId: String?,
        session: any SessionManagerProtocol
    ) async throws -> String {
        // The lookup must propagate read errors: swallowing one here would
        // treat "read failed" as "no DM exists" and mint a duplicate. Callers
        // retry; the single-flight below keeps concurrent retries single.
        if let existing = try session
            .conversationsRepository(for: [.allowed, .unknown])
            .findAgentDm(with: agentInboxId) {
            return existing.id
        }

        let task: Task<String, Error> = Self.inFlight.withLock { map in
            if let running = map[agentInboxId] {
                return running
            }
            let created = Task {
                // The task removes itself so the entry lives exactly as long
                // as the create, independent of any awaiting caller's
                // cancellation. The removal's withLock cannot run before the
                // insertion below completes: it blocks on this same lock.
                defer { Self.inFlight.withLock { $0[agentInboxId] = nil } }
                return try await createDm(
                    agentInboxId: agentInboxId,
                    originConversationId: originConversationId,
                    session: session
                )
            }
            map[agentInboxId] = created
            return created
        }
        return try await task.value
    }

    private static func createDm(
        agentInboxId: String,
        originConversationId: String?,
        session: any SessionManagerProtocol
    ) async throws -> String {
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
