import Foundation

/// Drives one relay turn end to end: mint, journal, trigger, then watch.
public final class AgentRelayClient: Sendable {
    private let api: any AgentRelayBackendAPI
    private let webhook: any AgentWebhookTransport
    private let store: any AgentChatWriterProtocol
    private let history: any AgentHistoryBuilding
    private let now: @Sendable () -> Date

    public init(
        api: any AgentRelayBackendAPI,
        webhook: any AgentWebhookTransport,
        store: any AgentChatWriterProtocol,
        history: any AgentHistoryBuilding,
        now: @escaping @Sendable () -> Date = Date.init
    ) {
        self.api = api
        self.webhook = webhook
        self.store = store
        self.history = history
        self.now = now
    }

    /// Mint, journal, trigger, then watch. Returns when the turn completes,
    /// fails, or the 10-minute watch deadline passes.
    public func send(
        prompt: String,
        provider: ExternalAgentProvider,
        connection: AgentConnection
    ) async throws -> AgentTurnOutcome {
        let startedAt = now()
        let mint = try await api.mint(provider: provider)
        let turn = AgentTurn(
            requestId: mint.requestId,
            provider: provider,
            status: .pending,
            prompt: prompt,
            createdAt: Date(),
            expiresAt: mint.expiresAt
        )
        try store.insertPending(turn)

        let priorHistory = try? history.history(excluding: mint.requestId)
        let payload = AgentWebhookPayload(
            requestId: mint.requestId,
            returnToken: mint.returnToken,
            prompt: prompt,
            history: priorHistory,
            reply: AgentWebhookPayload.Reply(mcpServer: mint.mcpUrl)
        )
        do {
            try await webhook.trigger(payload: payload, url: connection.webhookURL, auth: connection.auth)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            guard !Task.isCancelled else { throw CancellationError() }
            let relayError = mapWebhookError(error, provider: provider)
            try store.markFailed(requestId: mint.requestId, errorCode: relayError.code)
            return .failed(relayError)
        }
        return try await watch(requestId: mint.requestId, startedAt: startedAt)
    }

    /// Resume watching a pending turn (launch recovery, foreground).
    public func watch(requestId: String) async throws -> AgentTurnOutcome {
        try await watch(requestId: requestId, startedAt: now())
    }

    /// One-shot collect used by the NSE and by the foreground on push:
    /// fetch with wait_ms=0, persist the completed row (inserting one if
    /// this device never minted it), ack, mark acked. The only owner of the
    /// save-then-ack sequence outside `send`/`watch`; callers render the
    /// returned result and never ack themselves. Returns nil on 404.
    public func collect(requestId: String, provider: ExternalAgentProvider?) async throws -> AgentRelayTurnResult? {
        let outcome = try await api.fetch(requestId: requestId, waitMs: 0)
        switch outcome {
        case let .completed(result):
            // Push payloads carry a provider; the fallback matters only for a missing local row.
            try store.markCompleted(requestId: requestId, result: result, provider: provider ?? .town)
            try await api.ack(requestId: requestId)
            try store.markAcked(requestId: requestId)
            return result
        case .expired:
            try store.markExpired(requestId: requestId)
            return nil
        case .notFound, .pending:
            return nil
        }
    }

    func completedEntries() async throws -> [AgentRelayCompletedEntry] {
        try await api.listCompleted()
    }

    func acknowledge(requestId: String) async throws {
        try await api.ack(requestId: requestId)
    }

    private func watch(requestId: String, startedAt: Date) async throws -> AgentTurnOutcome {
        while true {
            try Task.checkCancellation()
            let elapsed: TimeInterval = now().timeIntervalSince(startedAt)
            let remainingMilliseconds: Int = max(0, Int((Constant.watchDeadline - elapsed) * 1_000))
            let waitMilliseconds: Int = min(Constant.longPollWaitMilliseconds, remainingMilliseconds)

            let outcome = try await api.fetch(requestId: requestId, waitMs: waitMilliseconds)
            switch outcome {
            case let .completed(result):
                try store.markCompleted(requestId: requestId, result: result, provider: .town)
                try await api.ack(requestId: requestId)
                try store.markAcked(requestId: requestId)
                return .completed(result)
            case .pending:
                guard remainingMilliseconds > 0 else { return .stillWorking }
                continue
            case .expired:
                try store.markExpired(requestId: requestId)
                return .expired
            case .notFound:
                try store.markCollectedElsewhere(requestId: requestId)
                return .collectedElsewhere
            }
        }
    }

    private func mapWebhookError(_ error: Error, provider: ExternalAgentProvider) -> AgentRelayError {
        if let relayError = error as? AgentRelayError {
            return relayError
        }
        guard let transportError = error as? AgentWebhookTransportError else {
            return .webhookUnreachable
        }
        switch transportError {
        case let .rejected(status):
            return .webhookRejected(provider: provider, status: status)
        case .unreachable:
            return .webhookUnreachable
        }
    }

    private enum Constant {
        static let longPollWaitMilliseconds: Int = 25_000
        static let watchDeadline: TimeInterval = 600
    }
}
