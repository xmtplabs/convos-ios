import Foundation

extension SessionManager {
    /// Whether eager agent-DM creation runs for this session: disabled in
    /// production (matching the prototype's UI gate) and under tests, where
    /// background creation against seeded fixtures would be noise. Reads the
    /// session's own environment, not `ConfigManager.shared` -- the global
    /// traps when unconfigured, which kills unit-test runners that construct
    /// a SessionManager.
    private var eagerAgentDmEnabled: Bool {
        switch environment {
        case .tests, .production:
            return false
        case .local, .dev:
            return true
        }
    }

    /// Returns the session-wide agent-DM reconciler, instantiating and starting
    /// it on first access. Ensures a DM exists for every verified agent in the
    /// user's conversations (see `AgentDmReconciler`).
    public func agentDmReconciler() -> AgentDmReconciler {
        agentDmReconcilerLock.withLock { existing in
            if let existing { return existing }
            let repository = conversationsRepository(for: [.allowed, .unknown])
            let new = AgentDmReconciler(
                conversationsPublisher: repository.conversationsPublisher,
                isEnabled: eagerAgentDmEnabled,
                hasExistingDm: { [weak self] agentInboxId in
                    guard let self else { return true }
                    let repository = self.conversationsRepository(for: [.allowed, .unknown])
                    // try? on an optional-returning call flattens to a single
                    // optional; nil means "no DM found or lookup failed" and
                    // either way creation may proceed (lookup-first downstream).
                    let found: Conversation? = (try? repository.findAgentDm(with: agentInboxId)) ?? nil
                    return found != nil
                },
                createDm: { [weak self] agentInboxId, originConversationId in
                    guard let self else { return false }
                    do {
                        _ = try await AgentDmFlow.startOrFindDm(
                            agentInboxId: agentInboxId,
                            originConversationId: originConversationId,
                            session: self
                        )
                        return true
                    } catch {
                        Log.error("AgentDmReconciler: failed to create DM for \(agentInboxId): \(error.localizedDescription)")
                        return false
                    }
                }
            )
            new.start()
            existing = new
            return new
        }
    }
}
