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

    /// One-shot cleanup of conversation shells stranded by earlier builds'
    /// eager DM creates (visible, unnamed, agent-less rows rendering as
    /// "New Convo" - see `StrandedConversationSweeper`). Gated with the
    /// reconciler because the shells it targets came from the same path.
    func sweepStrandedAgentDmShells() {
        guard eagerAgentDmEnabled else { return }
        Task(priority: .utility) { [weak self] in
            guard let self else { return }
            do {
                let swept = try await StrandedConversationSweeper.sweep(databaseWriter: self.databaseWriter)
                if swept > 0 {
                    Log.info("StrandedConversationSweeper: hid \(swept) stranded conversation shell(s)")
                }
            } catch {
                Log.error("StrandedConversationSweeper failed: \(error.localizedDescription)")
            }
        }
    }

    /// Stops and clears the session's reconciler; called from inbox teardown
    /// so an in-flight create cannot re-insert rows after the wipe.
    func stopAgentDmReconciler() {
        agentDmReconcilerLock.withLock { reconciler in
            reconciler?.stop()
            reconciler = nil
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
                    do {
                        // A lookup failure means "no DM known"; creation may
                        // proceed (the downstream flow is lookup-first anyway).
                        return try repository.findAgentDm(with: agentInboxId) != nil
                    } catch {
                        return false
                    }
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
