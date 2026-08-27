import Foundation
import GRDB

public struct DefaultAgentProvisionFailure: Equatable, Sendable {
    public let conversationId: String
    public let reason: String?

    public init(conversationId: String, reason: String?) {
        self.conversationId = conversationId
        self.reason = reason
    }
}

public extension Notification.Name {
    static let defaultAgentProvisionDidFail: Notification.Name = Notification.Name(
        "org.convos.defaultAgentProvisionDidFail"
    )
}

/// Per-conversation bookkeeping for the default-agent flow: dedupes concurrent
/// provisions (cache-time vs claim-time) by sharing one task per conversation
/// and keeps the join's idempotency key stable across retries.
actor DefaultConversationAgentCoordinator {
    private var provisionTasks: [String: Task<Void, Never>] = [:]
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

    /// Whether a provision has been started for this conversation and hasn't
    /// been forgotten as failed - that is, its default agent is on the way.
    /// The UI reads this so a conversation whose silent join is already in
    /// flight doesn't also offer to add an agent.
    func isProvisioning(_ conversationId: String) -> Bool {
        provisionTasks[conversationId] != nil
    }

    /// The idempotency key for the conversation's current logical join,
    /// minted on first use and stable across retries so the backend adopts
    /// the in-flight instance instead of provisioning a duplicate.
    func joinKey(for conversationId: String) -> ConvosAPI.JoinIdempotencyKey {
        if let existing = joinKeys[conversationId] {
            return existing
        }
        let key = ConvosAPI.JoinIdempotencyKey.mint()
        joinKeys[conversationId] = key
        return key
    }

    /// Forgets the key once its join has landed, or after an explicit
    /// provision failure — the server retains the failed instance under the
    /// old key, so reusing it can only fail again.
    func clearJoinKey(for conversationId: String) {
        joinKeys[conversationId] = nil
    }
}

// MARK: - Default agent in every conversation

extension SessionManager {
    /// Hook the app layer installs so a default-agent join routes to the same
    /// agent variant as every other agent call. Read at join time, so a build
    /// whose pin or selection changes mid-session applies it to the next
    /// provision. Nil (no app layer, e.g. tests) keeps joins on the default
    /// runtime, as does production via the API client's prod-safe strip.
    ///
    /// Takes the conversation because a variant is bound per conversation: the
    /// pick made while creating this one must beat whatever the global selector
    /// happens to hold now, exactly as every other agent call resolves it.
    /// Resolving globally here is what sent picked-variant agents to the
    /// default runtime while the rest of the conversation's calls routed right.
    public nonisolated(unsafe) static var defaultAgentVariantIdProvider: (@Sendable (String) async -> String?)?

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

    /// Hook the app layer installs to hold the warm cache's default-agent
    /// provision until the conversation is adopted. The cache provisions at
    /// preparation time, which is before a creation flow exists to pick a
    /// variant, so a prepared conversation's agent would always be built on
    /// whatever runtime was current when the row was minted — the pick could
    /// never apply to the one agent the conversation ships with. Holding it
    /// costs the pre-warm latency, so only the dev variant selector asks for
    /// it; `commitClaimedConversation` ensures the agent at adoption, after the
    /// variant is bound.
    public nonisolated(unsafe) static var deferCacheTimeDefaultAgent: (@Sendable () async -> Bool)?

    /// Hook the app layer installs to record which variant a freshly claimed
    /// conversation was created under. Called with the claimed conversation and
    /// the caller's pick — nil meaning "no variant", which clears — before the
    /// claim-time provision reads it. Nil hook (no app layer, e.g. tests) keeps
    /// conversations unbound.
    public nonisolated(unsafe) static var claimedConversationVariantBinder: (@Sendable (String, String?) async -> Void)?

    /// Wires the warm cache so every conversation it finishes preparing gets
    /// the default agent provisioned into it, best-effort, in the background —
    /// unless the app layer is holding that provision for a variant pick.
    func wireDefaultAgentProvisioner() {
        Task { [weak self, unusedConversationCache] in
            await unusedConversationCache.configureAgentProvisioner { [weak self] conversationId in
                if await Self.deferCacheTimeDefaultAgent?() == true {
                    Log.debug("Default agent: holding cache-time provision for \(conversationId) until adoption")
                    return
                }
                await self?.ensureDefaultAgentInConversation(id: conversationId)
            }
        }
    }

    /// Ensures the conversation has its default agent: no-op when an agent is
    /// already in it, otherwise provisions a bare agent (join with no
    /// template, greeting deferred) and adds it. Safe to call repeatedly -
    /// concurrent callers share one provision task, and a failed provision is
    /// retryable on the next call.
    func ensureDefaultAgentInConversation(id conversationId: String) async {
        guard Self.defaultAgentProvisioningEnabled(environment) else { return }
        let task = await defaultAgentCoordinator.provisionTask(for: conversationId) { [weak self] in
            await self?.runDefaultAgentProvision(conversationId: conversationId)
        }
        await task.value
    }

    /// Whether this conversation's default agent is already being provisioned
    /// (see `SessionManagerProtocol`).
    public func isProvisioningDefaultAgent(id conversationId: String) async -> Bool {
        guard Self.defaultAgentProvisioningEnabled(environment) else { return false }
        return await defaultAgentCoordinator.isProvisioning(conversationId)
    }

    /// Cache-miss entry point (see `SessionManagerProtocol`): a conversation
    /// the state machine created fresh never passes through
    /// `commitClaimedConversation`, so ensure its default agent here.
    public func ensureDefaultAgentConversationReady(id conversationId: String) async {
        await ensureDefaultAgentInConversation(id: conversationId)
    }

    private func runDefaultAgentProvision(conversationId: String) async {
        do {
            guard try await conversationLacksAgent(conversationId) else {
                Log.debug("Default agent: conversation \(conversationId) already has an agent, skipping provision")
                // Nothing is in flight, so nothing should read as in flight.
                // Leaving the task cached is what pinned the Agent tab in its
                // "preparing" state until the app relaunched.
                await defaultAgentCoordinator.clearProvisionTask(for: conversationId)
                return
            }
            let variantId = await Self.defaultAgentVariantIdProvider?(conversationId)
            let ownerProfileName = await currentOwnerProfileName()
            let response: ConvosAPI.AgentJoinResponse
            do {
                response = try await provisionDefaultAgent(
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
                response = try await provisionDefaultAgent(
                    conversationId: conversationId,
                    variantId: variantId,
                    ownerProfileName: ownerProfileName
                )
            }
            await defaultAgentCoordinator.clearJoinKey(for: conversationId)
            monitorDefaultAgentJoinCompletion(
                response: response,
                conversationId: conversationId,
                variantId: variantId
            )
            Log.info("Default agent: provisioned into conversation \(conversationId)")
        } catch {
            // An ambiguous terminal failure keeps the join key so a later
            // ensure (the claim-time backstop) adopts a join that actually
            // landed server-side instead of duplicating it. An explicit
            // provision failure clears the key — the server retains the failed
            // instance under it.
            if case APIError.agentProvisionFailed = error {
                await defaultAgentCoordinator.clearJoinKey(for: conversationId)
            }
            Log.error("Default agent: provisioning failed for conversation \(conversationId): \(error)")
            await defaultAgentCoordinator.clearProvisionTask(for: conversationId)
            publishDefaultAgentProvisionFailure(conversationId: conversationId, error: error)
        }
    }

    private func provisionDefaultAgent(
        conversationId: String,
        variantId: String?,
        ownerProfileName: String?
    ) async throws -> ConvosAPI.AgentJoinResponse {
        let idempotencyKey = await defaultAgentCoordinator.joinKey(for: conversationId)
        return try await addAgentToConversation(
            conversationId: conversationId,
            templateId: nil,
            options: .defaultConversationAgent(variantId: variantId),
            forceErrorCode: nil,
            idempotencyKey: idempotencyKey,
            ownerProfileName: ownerProfileName,
            grantAdmin: true
        )
    }

    private func monitorDefaultAgentJoinCompletion(
        response: ConvosAPI.AgentJoinResponse,
        conversationId: String,
        variantId: String?
    ) {
        guard !response.joined, let instanceId = response.instanceId else { return }
        Task { [weak self] in
            guard let self else { return }
            do {
                try await awaitAgentJoinCompletion(
                    instanceId: instanceId,
                    variantId: variantId
                )
            } catch is CancellationError {
                return
            } catch {
                await defaultAgentCoordinator.clearJoinKey(for: conversationId)
                await defaultAgentCoordinator.clearProvisionTask(for: conversationId)
                publishDefaultAgentProvisionFailure(conversationId: conversationId, error: error)
            }
        }
    }

    private func publishDefaultAgentProvisionFailure(
        conversationId: String,
        error: Error
    ) {
        let reason: String?
        if case APIError.agentProvisionFailed(let failureReason) = error {
            reason = failureReason
        } else {
            reason = nil
        }
        let failure = DefaultAgentProvisionFailure(
            conversationId: conversationId,
            reason: reason
        )
        NotificationCenter.default.post(name: .defaultAgentProvisionDidFail, object: failure)
    }

    /// The user's own profile name, nil when unset or unreadable. A brand-new
    /// session can fill the cache before the profile exists; the backend
    /// composes the agent's display name only when a name rides the join.
    private func currentOwnerProfileName() async -> String? {
        do {
            return try await databaseReader.read { db -> String? in
                guard let inboxId = try DBInbox.currentInboxId(db) else {
                    return nil
                }
                let name = try DBMyProfile
                    .filter(DBMyProfile.Columns.inboxId == inboxId)
                    .fetchOne(db)?
                    .name
                let trimmed = name?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                return trimmed.isEmpty ? nil : trimmed
            }
        } catch {
            Log.error("Default agent: reading owner profile name failed: \(error)")
            return nil
        }
    }

    /// Whether the conversation still needs a default agent: nobody in it is
    /// an agent, and nobody in it ever verified as one.
    ///
    /// Deliberately not "lacks a second member". Cache-prepared conversations
    /// start with the creator as sole member, so a bare member count answered
    /// this question for the provisioner's first caller - but it reads as "an
    /// agent is already here" for any conversation that has people in it,
    /// which silently dropped every user-initiated "Add an agent" tap (a
    /// conversation created before agents joined by default, or whose silent
    /// provision never landed - the two cases this path exists to serve).
    ///
    /// `hasHadVerifiedAgent` is the sticky historical answer; the member join
    /// is the live one, and settles first because it needs no key-package
    /// verification. Every `DBMemberKind` is an agent kind, so a member whose
    /// profile carries one is an agent. The current user has no `profile` row
    /// (self identity lives in `myProfile`), so the creator never matches.
    /// Internal rather than private so the unit suite can pin its semantics.
    func conversationLacksAgent(_ conversationId: String) async throws -> Bool {
        try await databaseReader.read { db in
            let hasHadVerifiedAgent = try DBConversation
                .filter(DBConversation.Columns.id == conversationId)
                .fetchOne(db)?
                .hasHadVerifiedAgent ?? false
            guard !hasHadVerifiedAgent else { return false }
            let agentMemberCount = try DBConversationMember
                .filter(DBConversationMember.Columns.conversationId == conversationId)
                .joining(
                    required: DBConversationMember.profile
                        .filter(DBProfile.Columns.memberKind != nil)
                )
                .fetchCount(db)
            return agentMemberCount == 0
        }
    }
}
