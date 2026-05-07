import Foundation

/// A single `(kind, capability, conversation, grantedToInboxId)` enablement quadruple.
///
/// Each row binds a verb on a connection kind to one specific agent within a
/// conversation. Two agents in the same conversation have independent rows; a grant
/// for one doesn't authorize the other. The cloud subsystem mirrors the same scoping
/// via `CloudConnectionGrantEntry.grantedToInboxId` and the runtime's
/// agent-ignorable rule.
public struct Enablement: Sendable, Hashable, Codable {
    public let kind: ConnectionKind
    public let capability: ConnectionCapability
    public let conversationId: String
    public let grantedToInboxId: String

    public init(
        kind: ConnectionKind,
        capability: ConnectionCapability,
        conversationId: String,
        grantedToInboxId: String
    ) {
        self.kind = kind
        self.capability = capability
        self.conversationId = conversationId
        self.grantedToInboxId = grantedToInboxId
    }
}

/// Persists `(kind, capability, conversation, grantedToInboxId)` enablement state
/// plus a per-`(kind, conversation)` "always confirm writes" flag.
///
/// Resolution lookups always include `grantedToInboxId`. The data-source fan-out
/// helper `conversationIds(enabledFor:capability:)` returns deduplicated conversation
/// ids — every conversation that has at least one agent enabled — because XMTP
/// broadcasts to the whole group anyway and the runtime's agent-ignorable rule scopes
/// the action.
public protocol EnablementStore: Sendable {
    func isEnabled(
        kind: ConnectionKind,
        capability: ConnectionCapability,
        conversationId: String,
        grantedToInboxId: String
    ) async -> Bool

    func setEnabled(
        _ enabled: Bool,
        kind: ConnectionKind,
        capability: ConnectionCapability,
        conversationId: String,
        grantedToInboxId: String
    ) async

    /// Conversations that have at least one agent enabled for this `(kind, capability)`.
    /// Used by data sources for fan-out — they don't need agent identity because the
    /// XMTP broadcast carries to the whole group.
    func conversationIds(enabledFor kind: ConnectionKind, capability: ConnectionCapability) async -> [String]

    func allEnablements() async -> [Enablement]

    // Always-confirm flag, scoped per `(kind, conversationId)` — not per capability or agent.
    func alwaysConfirmWrites(kind: ConnectionKind, conversationId: String) async -> Bool
    func setAlwaysConfirmWrites(_ alwaysConfirm: Bool, kind: ConnectionKind, conversationId: String) async
}
