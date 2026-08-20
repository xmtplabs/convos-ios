import Foundation

/// Launch and foreground recovery: saves and acks completed-but-unacked
/// mailboxes, resumes watching local pending rows, expires stale ones.
public final class AgentRelayRecoveryCoordinator: Sendable {
    private let client: AgentRelayClient
    private let repository: any AgentChatRepositoryProtocol
    private let writer: any AgentChatWriterProtocol

    public init(
        client: AgentRelayClient,
        repository: any AgentChatRepositoryProtocol,
        writer: any AgentChatWriterProtocol
    ) {
        self.client = client
        self.repository = repository
        self.writer = writer
    }

    public func runOnLaunch() async {
        await recover()
    }

    public func runOnForeground() async {
        await recover()
    }

    private func recover() async {
        let entries: [AgentRelayCompletedEntry]
        do {
            entries = try await client.completedEntries()
        } catch {
            entries = []
            Log.warning("Agent relay completed listing failed")
        }

        let listedRequestIds = Set(entries.map(\.requestId))
        for entry in entries {
            do {
                guard let localTurn = try repository.turn(requestId: entry.requestId) else {
                    try await client.acknowledge(requestId: entry.requestId)
                    continue
                }

                if localTurn.status == .pending {
                    _ = try await client.collect(requestId: entry.requestId, provider: entry.provider ?? localTurn.provider)
                } else if localTurn.status == .completed, localTurn.ackedAt == nil {
                    try await client.acknowledge(requestId: entry.requestId)
                    try writer.markAcked(requestId: entry.requestId)
                }
            } catch {
                Log.warning("Agent relay recovery failed for request \(entry.requestId.prefix(12))")
            }
        }

        let pendingTurns: [AgentTurn]
        do {
            pendingTurns = try repository.pendingTurns()
        } catch {
            Log.warning("Agent relay pending recovery read failed")
            return
        }

        let now = Date()
        for turn in pendingTurns where !listedRequestIds.contains(turn.requestId) {
            if turn.expiresAt <= now {
                try? writer.markExpired(requestId: turn.requestId)
                continue
            }
            Task { [client] in
                _ = try? await client.watch(requestId: turn.requestId)
            }
        }
    }
}
