import Foundation

/// Drives one relay turn end to end: mint, journal, trigger, then watch.
public final class AgentRelayClient: Sendable {
    private let api: any AgentRelayBackendAPI
    private let webhook: any AgentWebhookTransport
    private let store: any AgentChatWriterProtocol
    private let history: any AgentHistoryBuilding

    public init(
        api: any AgentRelayBackendAPI,
        webhook: any AgentWebhookTransport,
        store: any AgentChatWriterProtocol,
        history: any AgentHistoryBuilding
    ) {
        self.api = api
        self.webhook = webhook
        self.store = store
        self.history = history
    }

    /// Mint, journal, trigger, then watch. Returns when the turn completes,
    /// fails, or the 10-minute watch deadline passes.
    public func send(
        prompt: String,
        provider: ExternalAgentProvider,
        connection: AgentConnection
    ) async throws -> AgentTurnOutcome {
        throw AgentRelayError.notConnected
    }

    /// Resume watching a pending turn (launch recovery, foreground).
    public func watch(requestId: String) async throws -> AgentTurnOutcome {
        throw AgentRelayError.notConnected
    }

    /// One-shot collect used by the NSE and by the foreground on push:
    /// fetch with wait_ms=0, persist the completed row (inserting one if
    /// this device never minted it), ack, mark acked. The only owner of the
    /// save-then-ack sequence outside `send`/`watch`; callers render the
    /// returned result and never ack themselves. Returns nil on 404.
    public func collect(requestId: String, provider: ExternalAgentProvider?) async throws -> AgentRelayTurnResult? {
        throw AgentRelayError.notConnected
    }
}
