import Foundation

extension SessionManager {
    /// Returns the session-wide unsent-brief replayer, instantiating and
    /// starting it on first access. Replays builder briefs whose send the
    /// app died holding (see `UnsentBuilderBriefReplayer`); the replay goes
    /// through the normal builder-bundle path, so it is gated on agent
    /// membership like any other builder send.
    public func unsentBuilderBriefReplayer() -> UnsentBuilderBriefReplayer {
        unsentBriefReplayerLock.withLock { replayer in
            if let replayer { return replayer }
            let new = UnsentBuilderBriefReplayer(
                databaseReader: databaseReader
            ) { [weak self] brief in
                guard let self else { return }
                let writer = self.messagingService().messageWriter(
                    for: brief.conversationId,
                    backgroundUploadManager: UnavailableBackgroundUploadManager()
                )
                do {
                    try await writer.sendBuilderBundle(
                        text: brief.prompt,
                        bundleItems: [],
                        textClientMessageId: brief.textClientMessageId,
                        bundleClientMessageId: UUID().uuidString,
                        awaitsAgentJoin: true
                    )
                } catch {
                    Log.error("UnsentBuilderBriefReplayer: replay send failed for \(brief.conversationId): \(error.localizedDescription)")
                }
            }
            new.start()
            replayer = new
            return new
        }
    }
}
