import Foundation

/// Drives one relay turn end to end: mint, journal, trigger, then watch.
public final class AgentRelayClient: Sendable {
    private let api: any AgentRelayBackendAPI
    private let webhook: any AgentWebhookTransport
    private let store: any AgentChatWriterProtocol
    private let history: any AgentHistoryBuilding
    private let sleep: @Sendable (TimeInterval) async throws -> Void
    private let now: @Sendable () -> Date

    public init(
        api: any AgentRelayBackendAPI,
        webhook: any AgentWebhookTransport,
        store: any AgentChatWriterProtocol,
        history: any AgentHistoryBuilding,
        sleep: @escaping @Sendable (TimeInterval) async throws -> Void = {
            try await Task.sleep(nanoseconds: UInt64($0 * 1_000_000_000))
        },
        now: @escaping @Sendable () -> Date = Date.init
    ) {
        self.api = api
        self.webhook = webhook
        self.store = store
        self.history = history
        self.sleep = sleep
        self.now = now
    }

    /// Mint, journal, trigger, then watch. Returns when the turn completes,
    /// fails, or the 10-minute watch deadline passes.
    public func send(
        prompt: String,
        connection: AgentConnection
    ) async throws -> AgentTurnOutcome {
        let provider = connection.provider
        let startedAt = now()
        let mint = try await api.mint(provider: provider)
        let turn = AgentTurn(
            requestId: mint.requestId,
            provider: provider,
            status: .pending,
            prompt: prompt,
            createdAt: now(),
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
            let providerReader = store as? any AgentTurnProviderReading
            let resolvedProvider = try provider ?? providerReader?.provider(requestId: requestId)
            guard let resolvedProvider else {
                Log.warning("Agent relay collect could not attribute request \(requestId.prefix(12))")
                return nil
            }
            try store.markCompleted(requestId: requestId, result: result, provider: resolvedProvider)
            try await api.ack(requestId: requestId)
            try store.markAcked(requestId: requestId)
            return result
        case .expired:
            try store.markExpired(requestId: requestId)
            return nil
        case .notFound:
            try store.markCollectedElsewhere(requestId: requestId)
            return nil
        case .pending:
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
        var retryAttempt: Int = 0
        while true {
            try Task.checkCancellation()
            let elapsed: TimeInterval = now().timeIntervalSince(startedAt)
            let remainingMilliseconds: Int = max(0, Int((Constant.watchDeadline - elapsed) * 1_000))
            let waitMilliseconds: Int = min(Constant.longPollWaitMilliseconds, remainingMilliseconds)

            let outcome: AgentRelayFetchOutcome
            do {
                outcome = try await api.fetch(requestId: requestId, waitMs: waitMilliseconds)
                retryAttempt = 0
            } catch is CancellationError {
                throw CancellationError()
            } catch let error as AgentRelayError {
                guard !Task.isCancelled else { throw CancellationError() }
                guard error == .relayUnreachable else { throw error }
                let shouldRetry: Bool = try await backOffAfterFetchFailure(
                    error,
                    requestId: requestId,
                    startedAt: startedAt,
                    retryAttempt: retryAttempt
                )
                retryAttempt += 1
                guard shouldRetry else { return .stillWorking }
                continue
            } catch {
                guard !Task.isCancelled else { throw CancellationError() }
                let shouldRetry: Bool = try await backOffAfterFetchFailure(
                    error,
                    requestId: requestId,
                    startedAt: startedAt,
                    retryAttempt: retryAttempt
                )
                retryAttempt += 1
                guard shouldRetry else { return .stillWorking }
                continue
            }
            switch outcome {
            case let .completed(result):
                let providerReader = store as? any AgentTurnProviderReading
                let provider = try providerReader?.provider(requestId: requestId)
                guard let provider else {
                    Log.warning("Agent relay watch could not attribute request \(requestId.prefix(12))")
                    return .stillWorking
                }
                try store.markCompleted(requestId: requestId, result: result, provider: provider)
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

    private func backOffAfterFetchFailure(
        _ error: Error,
        requestId: String,
        startedAt: Date,
        retryAttempt: Int
    ) async throws -> Bool {
        let exponent: Int = min(retryAttempt, Constant.maximumBackoffExponent)
        let delay: TimeInterval = TimeInterval(1 << exponent)
        let elapsed: TimeInterval = now().timeIntervalSince(startedAt)
        let remaining: TimeInterval = max(0, Constant.watchDeadline - elapsed)
        Log.warning("Agent relay watch retrying request \(requestId.prefix(12)) after fetch failure: \(error.localizedDescription)")
        guard remaining > delay else {
            guard remaining > 0 else { return false }
            try await sleep(remaining)
            try Task.checkCancellation()
            return false
        }
        try await sleep(delay)
        try Task.checkCancellation()
        return true
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
        static let maximumBackoffExponent: Int = 3
    }
}
