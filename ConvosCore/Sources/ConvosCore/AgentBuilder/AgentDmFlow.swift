import Foundation
import os

public enum AgentDmFlowError: Error {
    /// A concurrent create for the same agent did not resolve in time.
    case creationInProgress
}

/// Client flow for starting (or resuming) a private DM with an agent that is
/// already a member of one of the user's conversations. The DM is a standard
/// 2-member conversation carrying the agent-DM custom-metadata marker; the
/// agent side accepts or leaves based on its own policy. See
/// docs/plans/agent-dms.md.
public enum AgentDmFlow {
    /// Agents with a create currently in flight in this process. Closes the
    /// lookup-then-create race between the reconciler and the DM page's
    /// first-send path: the second caller waits for the first create to
    /// finish and then resolves via lookup instead of minting a duplicate.
    /// (The backend's atomic per-peer reserve remains the cross-device
    /// authority; this only prevents same-process duplicates.)
    private static let creating: OSAllocatedUnfairLock<Set<String>> = .init(initialState: [])

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

        let claimed: Bool = Self.creating.withLock { set in
            guard !set.contains(agentInboxId) else { return false }
            set.insert(agentInboxId)
            return true
        }
        if !claimed {
            // Another caller is mid-create; wait it out and resolve by lookup.
            for _ in 0..<40 {
                try await Task.sleep(nanoseconds: 250_000_000)
                if let existing = try? session
                    .conversationsRepository(for: [.allowed, .unknown])
                    .findAgentDm(with: agentInboxId) {
                    return existing.id
                }
                let stillCreating = Self.creating.withLock { $0.contains(agentInboxId) }
                if !stillCreating { break }
            }
            if let existing = try session
                .conversationsRepository(for: [.allowed, .unknown])
                .findAgentDm(with: agentInboxId) {
                return existing.id
            }
            throw AgentDmFlowError.creationInProgress
        }
        defer { Self.creating.withLock { _ = $0.remove(agentInboxId) } }

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
