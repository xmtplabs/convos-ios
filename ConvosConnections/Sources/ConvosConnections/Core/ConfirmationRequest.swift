import Foundation

/// What the host app needs in order to render a "agent wants to do X" confirmation sheet.
///
/// Deliberately stringly-typed: the package cannot know which rendering shape the host
/// uses, so it offers the raw facts plus a `humanSummary` that sinks pre-compute.
public struct ConfirmationRequest: Sendable, Identifiable {
    public let id: UUID
    public let invocationId: String
    public let conversationId: String
    public let kind: ConnectionKind
    public let capability: ConnectionCapability
    public let actionName: String
    public let arguments: [String: ArgumentValue]
    public let humanSummary: String
    public let requestedAt: Date

    public init(
        id: UUID = UUID(),
        invocationId: String,
        conversationId: String,
        kind: ConnectionKind,
        capability: ConnectionCapability,
        actionName: String,
        arguments: [String: ArgumentValue],
        humanSummary: String,
        requestedAt: Date = Date()
    ) {
        self.id = id
        self.invocationId = invocationId
        self.conversationId = conversationId
        self.kind = kind
        self.capability = capability
        self.actionName = actionName
        self.arguments = arguments
        self.humanSummary = humanSummary
        self.requestedAt = requestedAt
    }
}

/// The user's response to a `ConfirmationRequest`.
public enum ConfirmationDecision: Sendable, Equatable {
    /// User approved; sink should proceed.
    case approved
    /// User explicitly denied; manager returns `authorizationDenied`.
    case denied
    /// UI could not be presented (app backgrounded, no window, etc.); manager returns
    /// `requiresConfirmation` so the agent knows to retry later.
    case cannotPresent
}

/// Host-implemented bridge for user confirmation. The package calls `confirm(_:)` at most
/// once per invocation; the host decides whether and how to present UI.
public protocol ConfirmationHandling: Sendable {
    func confirm(_ request: ConfirmationRequest) async -> ConfirmationDecision
}
