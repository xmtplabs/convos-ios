import Foundation

/// Agent-to-device invocation envelope. Transport-agnostic; the host app wraps this in an
/// XMTP content type at the messaging layer.
public struct ConnectionInvocation: Sendable, Equatable, Codable, Identifiable {
    public static let currentSchemaVersion: Int = 1

    public let id: UUID
    public let schemaVersion: Int
    public let invocationId: String
    public let kind: ConnectionKind
    public let action: ConnectionAction
    public let issuedAt: Date

    public init(
        id: UUID = UUID(),
        schemaVersion: Int = Self.currentSchemaVersion,
        invocationId: String,
        kind: ConnectionKind,
        action: ConnectionAction,
        issuedAt: Date = Date()
    ) {
        self.id = id
        self.schemaVersion = schemaVersion
        self.invocationId = invocationId
        self.kind = kind
        self.action = action
        self.issuedAt = issuedAt
    }
}

/// Device-to-agent reply envelope. Always emitted, even on error. `invocationId` echoes
/// the request so the agent can correlate.
public struct ConnectionInvocationResult: Sendable, Equatable, Codable, Identifiable {
    public static let currentSchemaVersion: Int = 1

    public enum Status: String, Sendable, Codable, Equatable {
        case success
        case capabilityNotEnabled = "capability_not_enabled"
        case capabilityRevoked = "capability_revoked"
        case requiresConfirmation = "requires_confirmation"
        case authorizationDenied = "authorization_denied"
        case executionFailed = "execution_failed"
        case unknownAction = "unknown_action"
    }

    public let id: UUID
    public let schemaVersion: Int
    public let invocationId: String
    public let kind: ConnectionKind
    public let actionName: String
    public let status: Status
    /// Populated only when `status == .success`. Keys match `ActionSchema.outputs`.
    public let result: [String: ArgumentValue]
    /// Human-readable failure description. Populated for non-success statuses where the
    /// underlying framework surfaced a message.
    public let errorMessage: String?
    public let completedAt: Date

    public init(
        id: UUID = UUID(),
        schemaVersion: Int = Self.currentSchemaVersion,
        invocationId: String,
        kind: ConnectionKind,
        actionName: String,
        status: Status,
        result: [String: ArgumentValue] = [:],
        errorMessage: String? = nil,
        completedAt: Date = Date()
    ) {
        self.id = id
        self.schemaVersion = schemaVersion
        self.invocationId = invocationId
        self.kind = kind
        self.actionName = actionName
        self.status = status
        self.result = result
        self.errorMessage = errorMessage
        self.completedAt = completedAt
    }
}
