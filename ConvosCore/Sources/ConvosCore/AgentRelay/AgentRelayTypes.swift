import Foundation

public enum AgentWebhookAuth: Equatable, Sendable {
    /// Town: `Authorization: Bearer <secret>` on the webhook call.
    case bearer(secret: String)
    /// Tasklet: the webhook URL is the secret; no auth header.
    case capabilityURL
}

public struct AgentRelayLink: Codable, Equatable, Sendable {
    public let title: String?
    public let url: URL

    public init(title: String?, url: URL) {
        self.title = title
        self.url = url
    }
}

public struct AgentRelayTurnResult: Codable, Equatable, Sendable {
    public let message: String
    public let links: [AgentRelayLink]
    public let completedAt: Date

    public init(message: String, links: [AgentRelayLink], completedAt: Date) {
        self.message = message
        self.links = links
        self.completedAt = completedAt
    }
}

public struct AgentRelayMint: Decodable, Sendable {
    public let requestId: String
    public let returnToken: String
    public let mcpUrl: URL
    public let expiresAt: Date

    public init(requestId: String, returnToken: String, mcpUrl: URL, expiresAt: Date) {
        self.requestId = requestId
        self.returnToken = returnToken
        self.mcpUrl = mcpUrl
        self.expiresAt = expiresAt
    }
}

public enum AgentRelayFetchOutcome: Equatable, Sendable {
    case completed(AgentRelayTurnResult)
    case pending(expiresAt: Date)
    case expired
    case notFound
}

/// One entry of the recovery listing (`GET /requests?status=completed`).
/// `result.completedAt` carries the entry's `completedAt`.
public struct AgentRelayCompletedEntry: Equatable, Sendable {
    public let requestId: String
    public let provider: ExternalAgentProvider?
    public let result: AgentRelayTurnResult

    public init(requestId: String, provider: ExternalAgentProvider?, result: AgentRelayTurnResult) {
        self.requestId = requestId
        self.provider = provider
        self.result = result
    }
}

public struct AgentConnection: Equatable, Sendable {
    public let provider: ExternalAgentProvider
    public let webhookURL: URL
    public let auth: AgentWebhookAuth

    public init(provider: ExternalAgentProvider, webhookURL: URL, auth: AgentWebhookAuth) {
        self.provider = provider
        self.webhookURL = webhookURL
        self.auth = auth
    }
}

public enum AgentTurnOutcome: Equatable, Sendable {
    case completed(AgentRelayTurnResult)
    case failed(AgentRelayError)
    case expired
    case stillWorking
    case collectedElsewhere
}

public enum AgentRelayError: Error, Equatable, Sendable {
    case notConnected
    case validation(String)
    case relayUnreachable
    case relayRejected(Int)
    case webhookRejected(provider: ExternalAgentProvider, status: Int)
    case webhookUnreachable
    case unreadableResult
    case expired
    case stillWorking
    case cancelled

    /// Stable identifier persisted in `agent_turn.errorCode`.
    public var code: String {
        switch self {
        case .notConnected: return "notConnected"
        case .validation: return "validation"
        case .relayUnreachable: return "relayUnreachable"
        case .relayRejected(let status): return "relayRejected:\(status)"
        case let .webhookRejected(provider, status): return "webhookRejected:\(provider.rawValue):\(status)"
        case .webhookUnreachable: return "webhookUnreachable"
        case .unreadableResult: return "unreadableResult"
        case .expired: return "expired"
        case .stillWorking: return "stillWorking"
        case .cancelled: return "cancelled"
        }
    }
}
