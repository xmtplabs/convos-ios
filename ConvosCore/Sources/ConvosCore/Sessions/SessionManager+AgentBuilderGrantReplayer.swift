import Foundation

extension SessionManager {
    /// Returns the session-wide AgentBuilder grant replayer, instantiating
    /// and starting it on first access. Idempotent — `start()` cancels the
    /// previous observation task before kicking off a new one, but normal
    /// callers only hit this once during session bootstrap.
    public func agentBuilderConnectionGrantReplayer() -> AgentBuilderConnectionGrantReplayer {
        agentBuilderGrantReplayerLock.withLock { replayer in
            if let replayer { return replayer }
            let new = AgentBuilderConnectionGrantReplayer(
                databaseReader: databaseReader,
                grantWriter: messagingService().connectionGrantWriter(),
                cloudConnectionRepository: cloudConnectionRepository(),
                connectionEventWriter: messagingService().connectionEventWriter(),
                enablementStore: connectionEnablementStore(),
                summaryWriter: agentBuilderSummaryWriter()
            )
            new.start()
            replayer = new
            return new
        }
    }
}
