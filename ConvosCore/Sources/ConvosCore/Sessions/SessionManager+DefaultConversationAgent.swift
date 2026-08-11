import Foundation
import GRDB

/// Per-conversation bookkeeping for the default-agent flow: dedupes concurrent
/// provisions (cache-time vs claim-time) by sharing one task per conversation,
/// and latches the one-shot `conversation_ready` send.
actor DefaultConversationAgentCoordinator {
    private var provisionTasks: [String: Task<Void, Never>] = [:]
    private var readySignaledConversationIds: Set<String> = []
    private var joinKeys: [String: ConvosAPI.JoinIdempotencyKey] = [:]

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

    /// The idempotency key for the conversation's current logical join, minted
    /// on first use and stable across retries so the backend adopts the
    /// in-flight instance instead of provisioning a duplicate.
    func joinKey(for conversationId: String) -> ConvosAPI.JoinIdempotencyKey {
        if let existing = joinKeys[conversationId] {
            return existing
        }
        let key = ConvosAPI.JoinIdempotencyKey.mint()
        joinKeys[conversationId] = key
        return key
    }

    /// Forgets the key once its join has landed, or after an explicit provision
    /// failure - the server retains the failed instance under the old key, so
    /// reusing it can only fail again.
    func clearJoinKey(for conversationId: String) {
        joinKeys[conversationId] = nil
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

    /// App-installed gate for whether every conversation gets a bare default
    /// agent. The desktop line installs it reading `isDesktopModeEnabled`;
    /// contexts that leave it nil (extensions, non-desktop builds) keep the
    /// flow off. Read at ensure time so toggling desktop mode applies to the
    /// next conversation.
    public nonisolated(unsafe) static var defaultAgentProvisioningEnabledProvider: (@Sendable () async -> Bool)?

    /// Never provision under tests (the local stack has no assistant runtime);
    /// otherwise defer to the app-installed gate, off when none is installed.
    func isDefaultAgentProvisioningEnabled() async -> Bool {
        if case .tests = environment { return false }
        return await Self.defaultAgentProvisioningEnabledProvider?() ?? false
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
        guard await isDefaultAgentProvisioningEnabled() else { return }
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
    /// joined with its greeting suppressed and this message is what prompts the
    /// welcome. Best-effort and fully async; callers fire-and-forget.
    func sendConversationReadySignalIfNeeded(conversationId: String) async {
        guard await isDefaultAgentProvisioningEnabled() else { return }
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
            let variantId = await Self.defaultAgentVariantIdProvider?()
            let ownerProfileName = await currentOwnerProfileName()
            do {
                try await provisionDefaultAgent(
                    conversationId: conversationId,
                    variantId: variantId,
                    ownerProfileName: ownerProfileName
                )
            } catch {
                // One idempotent retry. An explicit provision failure clears
                // the key first (the server retains the failed instance under
                // it); every other failure reuses the key so the server adopts
                // the in-flight instance instead of provisioning a duplicate.
                if case APIError.agentProvisionFailed = error {
                    await defaultAgentCoordinator.clearJoinKey(for: conversationId)
                }
                Log.error("Default agent: provision attempt failed for conversation \(conversationId), retrying once: \(error)")
                try await provisionDefaultAgent(
                    conversationId: conversationId,
                    variantId: variantId,
                    ownerProfileName: ownerProfileName
                )
            }
            await defaultAgentCoordinator.clearJoinKey(for: conversationId)
            Log.info("Default agent: provisioned into conversation \(conversationId)")
        } catch {
            // An ambiguous terminal failure keeps the join key so a later
            // ensure (the claim-time backstop) adopts a join that actually
            // landed server-side instead of duplicating it. An explicit
            // provision failure clears the key - the server retains the failed
            // instance under it.
            if case APIError.agentProvisionFailed = error {
                await defaultAgentCoordinator.clearJoinKey(for: conversationId)
            }
            Log.error("Default agent: provisioning failed for conversation \(conversationId): \(error)")
            await defaultAgentCoordinator.clearProvisionTask(for: conversationId)
        }
    }

    private func provisionDefaultAgent(
        conversationId: String,
        variantId: String?,
        ownerProfileName: String?
    ) async throws {
        let idempotencyKey = await defaultAgentCoordinator.joinKey(for: conversationId)
        _ = try await addAgentToConversation(
            conversationId: conversationId,
            templateId: nil,
            options: .defaultConversationAgent(variantId: variantId),
            forceErrorCode: nil,
            idempotencyKey: idempotencyKey,
            ownerProfileName: ownerProfileName,
            grantAdmin: true
        )
    }

    /// Cache-prepared conversations start with the creator as sole member, so a
    /// second member row means the default agent (or someone else) is already
    /// in.
    private func conversationLacksSecondMember(_ conversationId: String) async throws -> Bool {
        try await databaseReader.read { db in
            try DBConversationMember
                .filter(DBConversationMember.Columns.conversationId == conversationId)
                .fetchCount(db) <= 1
        }
    }
}
