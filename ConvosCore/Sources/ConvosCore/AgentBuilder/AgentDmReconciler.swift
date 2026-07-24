import Combine
import Foundation
import os

/// Session-scoped service that ensures the user has a private DM with every
/// verified agent present in their conversations. The DM is created when an
/// agent shows up in a group (and on launch catch-up over existing groups),
/// not lazily on the first message, so the DM exists as soon as the agent
/// does. See docs/plans/agent-dms.md.
///
/// The trigger is membership-driven, not view-driven: it observes the
/// conversations publisher (which already re-emits on any membership change),
/// so a live agent-join and a cold-launch catch-up are handled by the same
/// path. There is no per-view creation.
///
/// Creation is deduplicated at every layer that could race:
/// - a reconcile pass skips any agent that already has a DM;
/// - an in-flight set keyed by agent inbox blocks a second create while the
///   first is still landing its conversation row (the window the DB query
///   cannot yet see);
/// - `AgentDmFlow.startOrFindDm` is lookup-first;
/// - the backend's atomic reserve is the final authority across devices.
/// A DM is keyed by (me, agent), so an agent shared by several groups still
/// yields a single DM.
/// All mutable state is lock-guarded and the publisher is set once at init and
/// only consumed, so the unchecked Sendable conformance is sound.
public final class AgentDmReconciler: @unchecked Sendable {
    private let conversationsPublisher: AnyPublisher<[Conversation], Never>
    private let hasExistingDm: @Sendable (String) -> Bool
    /// Creates the DM; returns false on failure. A failed agent is not retried
    /// this session (see `failedAgents`).
    private let createDm: @Sendable (_ agentInboxId: String, _ originConversationId: String?) async -> Bool
    private let isEnabled: Bool

    /// Agents whose DM is mid-creation. Guards the window between issuing a
    /// create and the new conversation row becoming visible to `hasExistingDm`.
    private let inFlight: OSAllocatedUnfairLock<Set<String>> = .init(initialState: [])
    /// Agents whose creation failed once. The publisher re-emits on every
    /// database change, so retrying on each emission would hammer a failing
    /// backend and pile up half-created conversations. One attempt per agent
    /// per session; the DM page's first-send path remains the fallback.
    private let failedAgents: OSAllocatedUnfairLock<Set<String>> = .init(initialState: [])
    private let task: OSAllocatedUnfairLock<Task<Void, Never>?> = .init(initialState: nil)

    public init(
        conversationsPublisher: AnyPublisher<[Conversation], Never>,
        isEnabled: Bool,
        hasExistingDm: @escaping @Sendable (String) -> Bool,
        createDm: @escaping @Sendable (_ agentInboxId: String, _ originConversationId: String?) async -> Bool
    ) {
        self.conversationsPublisher = conversationsPublisher
        self.isEnabled = isEnabled
        self.hasExistingDm = hasExistingDm
        self.createDm = createDm
    }

    public func start() {
        guard isEnabled else { return }
        let new: Task<Void, Never> = Task { [weak self] in
            await self?.observe()
        }
        task.withLock { existing in
            existing?.cancel()
            existing = new
        }
    }

    public func stop() {
        task.withLock { existing in
            existing?.cancel()
            existing = nil
        }
    }

    private func observe() async {
        for await conversations in conversationsPublisher.values {
            if Task.isCancelled { return }
            await reconcile(conversations)
        }
    }

    private func reconcile(_ conversations: [Conversation]) async {
        // The first non-DM conversation each verified agent was seen in, used
        // as the DM's origin. Agent DMs are skipped so a DM's own agent member
        // never triggers a second DM.
        var originByAgent: [String: String] = [:]
        for conversation in conversations where !conversation.isAgentDm {
            for member in conversation.members where member.isVerifiedAgent {
                if originByAgent[member.profile.inboxId] == nil {
                    originByAgent[member.profile.inboxId] = conversation.id
                }
            }
        }

        for (agentInboxId, originConversationId) in originByAgent {
            if Task.isCancelled { return }
            if failedAgents.withLock({ $0.contains(agentInboxId) }) { continue }
            if hasExistingDm(agentInboxId) { continue }
            let claimed: Bool = inFlight.withLock { set in
                guard !set.contains(agentInboxId) else { return false }
                set.insert(agentInboxId)
                return true
            }
            guard claimed else { continue }
            let created = await createDm(agentInboxId, originConversationId)
            if !created {
                failedAgents.withLock { _ = $0.insert(agentInboxId) }
            }
            inFlight.withLock { $0.remove(agentInboxId) }
        }
    }
}
