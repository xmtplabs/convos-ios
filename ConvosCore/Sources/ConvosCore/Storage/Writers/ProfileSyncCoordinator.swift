import Foundation

/// Serializes activate-sync work per `conversationId` so two `.ready` transitions for the
/// same conversation can't race and double-upload. Each new request waits for the prior
/// task on the same conversationId to complete before running, picking up the latest
/// global-profile state on the second pass.
public actor ProfileSyncCoordinator {
    public static let shared: ProfileSyncCoordinator = .init()

    private var pending: [String: Task<Void, Never>] = [:]

    public func run(conversationId: String, _ work: @escaping @Sendable () async -> Void) {
        let previous = pending[conversationId]
        let token = UUID()
        let task = Task { [weak self, previous] in
            await previous?.value
            await work()
            await self?.clear(conversationId: conversationId, token: token)
        }
        pending[conversationId] = task
        tokens[conversationId] = token
    }

    private var tokens: [String: UUID] = [:]

    private func clear(conversationId: String, token: UUID) {
        if tokens[conversationId] == token {
            pending[conversationId] = nil
            tokens[conversationId] = nil
        }
    }
}
