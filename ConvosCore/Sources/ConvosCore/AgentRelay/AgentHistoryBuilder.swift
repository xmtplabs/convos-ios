import Foundation

/// Builds the optional `history` array of the webhook payload from the
/// device's own transcript: completed turns only, oldest first.
public protocol AgentHistoryBuilding: Sendable {
    func history(excluding requestId: String?) throws -> [AgentWebhookHistoryEntry]
}

public final class AgentHistoryBuilder: AgentHistoryBuilding {
    private let repository: any AgentChatRepositoryProtocol

    public init(repository: any AgentChatRepositoryProtocol) {
        self.repository = repository
    }

    public func history(excluding requestId: String?) throws -> [AgentWebhookHistoryEntry] {
        let turns = try repository.turns(limit: Int.max)
        let completedTurns = turns.filter { turn in
            turn.status == .completed && turn.requestId != requestId
        }.suffix(Constant.maximumTurns)

        var entries: [AgentWebhookHistoryEntry] = []
        for turn in completedTurns {
            guard let resultMessage = turn.resultMessage, let completedAt = turn.completedAt else { continue }
            entries.append(AgentWebhookHistoryEntry(role: "user", text: turn.prompt, at: turn.createdAt))
            entries.append(AgentWebhookHistoryEntry(role: "agent", text: resultMessage, at: completedAt))
        }

        var characterCount = entries.reduce(into: 0) { count, entry in
            count += entry.text.count
        }
        while characterCount > Constant.maximumCharacters, let oldest = entries.first {
            characterCount -= oldest.text.count
            entries.removeFirst()
        }
        return entries
    }

    private enum Constant {
        static let maximumCharacters: Int = 40_000
        static let maximumTurns: Int = 10
    }
}
