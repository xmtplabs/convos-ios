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
        []
    }
}
