import Foundation
import GRDB

public enum AgentTurnStatus: String, Codable, Sendable {
    case pending
    case completed
    case failed
    case expired
    case collectedElsewhere // swiftlint:disable:this raw_value_for_camel_cased_codable_enum
    /// The user sent another message while this turn was still in flight, so
    /// the device stopped waiting for it. Nothing was cancelled on the agent's
    /// own platform and the backend mailbox stays live, so a late answer is
    /// still collected and the row still becomes `completed` in place.
    case superseded
}

/// One relay turn: the in-flight journal while pending and the transcript
/// entry once completed. Lives in `agent-chat.sqlite`, never in the
/// conversation database.
public struct AgentTurn: Codable, Equatable, Identifiable, Sendable, FetchableRecord, PersistableRecord {
    public static let databaseTableName: String = "agent_turn"
    public static let databaseDateEncodingStrategy: DatabaseDateEncodingStrategy = .timeIntervalSince1970
    public static let databaseDateDecodingStrategy: DatabaseDateDecodingStrategy = .timeIntervalSince1970

    public var id: String { requestId }

    public let requestId: String
    public let provider: ExternalAgentProvider
    public var status: AgentTurnStatus
    public let prompt: String
    public var resultMessage: String?
    public var resultLinks: [AgentRelayLink]
    public var errorCode: String?
    public let createdAt: Date
    public let expiresAt: Date
    public var completedAt: Date?
    public var ackedAt: Date?

    public init(
        requestId: String,
        provider: ExternalAgentProvider,
        status: AgentTurnStatus,
        prompt: String,
        resultMessage: String? = nil,
        resultLinks: [AgentRelayLink] = [],
        errorCode: String? = nil,
        createdAt: Date,
        expiresAt: Date,
        completedAt: Date? = nil,
        ackedAt: Date? = nil
    ) {
        self.requestId = requestId
        self.provider = provider
        self.status = status
        self.prompt = prompt
        self.resultMessage = resultMessage
        self.resultLinks = resultLinks
        self.errorCode = errorCode
        self.createdAt = createdAt
        self.expiresAt = expiresAt
        self.completedAt = completedAt
        self.ackedAt = ackedAt
    }
}
