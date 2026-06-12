import Foundation

// MARK: - Handled Join Request Store Protocol

/// Ledger of join-request messages that have already admitted their sender.
///
/// Join-request DMs are durable, and several paths (message stream, batch
/// catch-up, the agent-join poll, the notification service extension) can
/// revalidate the same message long after it was first honored. Group
/// membership alone cannot dedupe those passes: once the creator removes
/// the member, the old request looks actionable again and silently re-adds
/// someone the user just removed. Keying handled requests by message ID
/// makes each request admit its sender at most once. Removal is not a
/// block - a removed member can rejoin with the same invite by sending a
/// fresh join request, which carries a new message ID.
public protocol HandledJoinRequestStoreProtocol: Sendable {
    /// Whether this join-request message already admitted its sender.
    func isHandled(messageId: String) async -> Bool

    /// Record that this join-request message admitted its sender, or was
    /// observed already satisfied (sender in the group).
    func markHandled(messageId: String) async
}

// MARK: - Default Implementation

/// In-memory store, suitable for tests and single-pass tools. Apps should
/// inject a persistent implementation so the ledger survives across
/// processing passes and across processes (app and notification service
/// extension).
public actor InMemoryHandledJoinRequestStore: HandledJoinRequestStoreProtocol {
    private var handledMessageIds: Set<String> = []

    public init() {}

    public func isHandled(messageId: String) async -> Bool {
        handledMessageIds.contains(messageId)
    }

    public func markHandled(messageId: String) async {
        handledMessageIds.insert(messageId)
    }
}
