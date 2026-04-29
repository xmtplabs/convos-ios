import Foundation

/// A single `(connection, capability, conversation)` enablement triple.
///
/// Per-assistant scoping is deliberately omitted; everyone in an XMTP conversation sees
/// every message, so a per-assistant gate would give a false sense of control.
public struct Enablement: Sendable, Hashable, Codable {
    public let kind: ConnectionKind
    public let capability: ConnectionCapability
    public let conversationId: String

    public init(kind: ConnectionKind, capability: ConnectionCapability, conversationId: String) {
        self.kind = kind
        self.capability = capability
        self.conversationId = conversationId
    }

    /// Backward-compatible init: call sites that predate the capability model are
    /// implicitly talking about `.read`.
    public init(kind: ConnectionKind, conversationId: String) {
        self.init(kind: kind, capability: .read, conversationId: conversationId)
    }
}

/// Persists `(kind, capability, conversation)` enablement state plus a per-`(kind, conversation)`
/// "always confirm writes" flag.
///
/// Backward compatibility: conforming types only need to implement the per-capability
/// methods; the legacy three-argument methods get default-implementation shims that
/// delegate to the `.read` capability so existing call sites continue to work.
public protocol EnablementStore: Sendable {
    // Per-capability API (required).
    func isEnabled(kind: ConnectionKind, capability: ConnectionCapability, conversationId: String) async -> Bool
    func setEnabled(_ enabled: Bool, kind: ConnectionKind, capability: ConnectionCapability, conversationId: String) async
    func conversationIds(enabledFor kind: ConnectionKind, capability: ConnectionCapability) async -> [String]
    func allEnablements() async -> [Enablement]

    // Always-confirm flag, scoped per `(kind, conversationId)` — not per capability.
    func alwaysConfirmWrites(kind: ConnectionKind, conversationId: String) async -> Bool
    func setAlwaysConfirmWrites(_ alwaysConfirm: Bool, kind: ConnectionKind, conversationId: String) async
}

public extension EnablementStore {
    // Backward-compatible read-only shims. Existing call sites keep compiling.
    func isEnabled(kind: ConnectionKind, conversationId: String) async -> Bool {
        await isEnabled(kind: kind, capability: .read, conversationId: conversationId)
    }

    func setEnabled(_ enabled: Bool, kind: ConnectionKind, conversationId: String) async {
        await setEnabled(enabled, kind: kind, capability: .read, conversationId: conversationId)
    }

    func conversationIds(enabledFor kind: ConnectionKind) async -> [String] {
        await conversationIds(enabledFor: kind, capability: .read)
    }
}
