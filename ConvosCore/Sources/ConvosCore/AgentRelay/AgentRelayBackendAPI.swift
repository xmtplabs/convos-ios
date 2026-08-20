import Foundation

/// The relay's return path on convos-backend: mint, long-poll, ack, and the
/// restart-recovery listing. Implemented over the authenticated API client
/// by `AgentRelayHTTPAPI`; tests script it with a fake.
public protocol AgentRelayBackendAPI: Sendable {
    func mint(provider: ExternalAgentProvider) async throws -> AgentRelayMint
    func fetch(requestId: String, waitMs: Int) async throws -> AgentRelayFetchOutcome
    func ack(requestId: String) async throws
    func listCompleted() async throws -> [AgentRelayCompletedEntry]
}

/// `AgentRelayBackendAPI` over `ConvosAPIClientProtocol.authorizedRequest`,
/// executed on a dedicated session so long-poll responses never pass
/// through the client's body-logging path.
public final class AgentRelayHTTPAPI: AgentRelayBackendAPI {
    private let apiClient: any ConvosAPIClientProtocol

    public init(apiClient: any ConvosAPIClientProtocol) {
        self.apiClient = apiClient
    }

    public func mint(provider: ExternalAgentProvider) async throws -> AgentRelayMint {
        throw AgentRelayError.notConnected
    }

    public func fetch(requestId: String, waitMs: Int) async throws -> AgentRelayFetchOutcome {
        throw AgentRelayError.notConnected
    }

    public func ack(requestId: String) async throws {
        throw AgentRelayError.notConnected
    }

    public func listCompleted() async throws -> [AgentRelayCompletedEntry] {
        []
    }
}
