import Foundation
import GRDB

/// Per-conversation bookkeeping for the default-agent flow: dedupes concurrent
/// provisions (cache-time vs claim-time) by sharing one task per conversation,
/// and latches the one-shot `conversation_ready` send.
actor DefaultConversationAgentCoordinator {
    private var provisionTasks: [String: Task<Void, Never>] = [:]
    private var readySignaledConversationIds: Set<String> = []

    /// Returns the in-flight (or completed) provision task for the
    /// conversation, creating it from `operation` on first call. Callers await
    /// the returned task so a claim-time ensure blocks on the cache-time
    /// provision instead of racing it.
    func provisionTask(
        for conversationId: String,
        operation: @escaping @Sendable () async -> Void
    ) -> Task<Void, Never> {
        if let existing = provisionTasks[conversationId] {
            return existing
        }
        let task = Task { await operation() }
        provisionTasks[conversationId] = task
        return task
    }

    /// Forgets a failed provision so a later ensure can retry it.
    func clearProvisionTask(for conversationId: String) {
        provisionTasks[conversationId] = nil
    }

    /// One-shot latch for the ready signal; true only on the first call per
    /// conversation per process.
    func shouldSendReadySignal(for conversationId: String) -> Bool {
        readySignaledConversationIds.insert(conversationId).inserted
    }
}

// MARK: - Default agent in every conversation

extension SessionManager {
    /// Dev-only hook the app layer installs to route default-agent joins to a
    /// selected agent-variant runtime (FeatureFlags' variant picker). Read at
    /// join time so a mid-session selection change applies to the next
    /// provision. Nil (default, and always in production via the API client's
    /// prod-safe strip) keeps joins on the default runtime.
    public nonisolated(unsafe) static var defaultAgentVariantIdProvider: (@Sendable () async -> String?)?

    /// Every conversation gets a bare default agent (no template) pre-added
    /// while it still sits hidden in the warm cache. Disabled for unit tests,
    /// which run against a local stack with no assistant runtime.
    static func defaultAgentProvisioningEnabled(_ environment: AppEnvironment) -> Bool {
        switch environment {
        case .tests:
            return false
        case .local, .dev, .production:
            return true
        }
    }

    /// Wires the warm cache so every conversation it finishes preparing gets
    /// the default agent provisioned into it, best-effort, in the background.
    func wireDefaultAgentProvisioner() {
        Task { [weak self, unusedConversationCache] in
            await unusedConversationCache.configureAgentProvisioner { [weak self] conversationId in
                await self?.ensureDefaultAgentInConversation(id: conversationId)
            }
        }
    }

    /// Ensures the conversation has its default agent: no-op when the
    /// conversation already has a second member, otherwise provisions a bare
    /// agent (join with no template, greeting deferred) and adds it. Safe to
    /// call repeatedly - concurrent callers share one provision task, and a
    /// failed provision is retryable on the next call.
    func ensureDefaultAgentInConversation(id conversationId: String) async {
        guard Self.defaultAgentProvisioningEnabled(environment) else { return }
        let task = await defaultAgentCoordinator.provisionTask(for: conversationId) { [weak self] in
            await self?.runDefaultAgentProvision(conversationId: conversationId)
        }
        await task.value
    }

    /// Cache-miss entry point (see `SessionManagerProtocol`): same ensure +
    /// ready-cue sequence the claimed-cache commit path runs.
    public func ensureDefaultAgentConversationReady(id conversationId: String) async {
        await sendConversationReadySignalIfNeeded(conversationId: conversationId)
    }

    /// Fires the invisible `conversation_ready` cue once per conversation,
    /// after making sure its default agent has actually landed - the agent
    /// joined with its greeting suppressed and this message is what prompts
    /// the welcome. Best-effort and fully async; callers fire-and-forget.
    func sendConversationReadySignalIfNeeded(conversationId: String) async {
        guard Self.defaultAgentProvisioningEnabled(environment) else { return }
        await ensureDefaultAgentInConversation(id: conversationId)
        guard await defaultAgentCoordinator.shouldSendReadySignal(for: conversationId) else { return }
        await messagingService().sendConversationReadySignal(for: conversationId)
    }

    private func runDefaultAgentProvision(conversationId: String) async {
        do {
            guard try await conversationLacksSecondMember(conversationId) else {
                Log.debug("Default agent: conversation \(conversationId) already has a second member, skipping provision")
                return
            }
            _ = try await addAgentToConversation(
                conversationId: conversationId,
                templateId: nil,
                options: .defaultConversationAgent(variantId: await Self.defaultAgentVariantIdProvider?()),
                forceErrorCode: nil,
                idempotencyKey: nil
            )
            Log.info("Default agent: provisioned into conversation \(conversationId)")
        } catch {
            Log.error("Default agent: provisioning failed for conversation \(conversationId): \(error)")
            await defaultAgentCoordinator.clearProvisionTask(for: conversationId)
        }
    }

    /// Cache-prepared conversations start with the creator as sole member, so
    /// a second member row means the default agent (or someone else) is
    /// already in.
    private func conversationLacksSecondMember(_ conversationId: String) async throws -> Bool {
        try await databaseReader.read { db in
            try DBConversationMember
                .filter(DBConversationMember.Columns.conversationId == conversationId)
                .fetchCount(db) <= 1
        }
    }
}
