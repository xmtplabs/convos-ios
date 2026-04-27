import Foundation

/// In-memory `EnablementStore` used by tests, previews, and the debug view.
///
/// The host app (Convos) supplies a persistent implementation backed by GRDB. This
/// in-memory variant is intentionally simple: a `Set<Enablement>` for the triples plus a
/// `[AlwaysConfirmKey: Bool]` for the always-confirm flag.
public actor InMemoryEnablementStore: EnablementStore {
    private var enablements: Set<Enablement>
    private var alwaysConfirm: [AlwaysConfirmKey: Bool]

    private struct AlwaysConfirmKey: Hashable, Sendable {
        let kind: ConnectionKind
        let conversationId: String
    }

    public struct AlwaysConfirmInitial: Sendable {
        public let kind: ConnectionKind
        public let conversationId: String
        public let isOn: Bool

        public init(kind: ConnectionKind, conversationId: String, isOn: Bool) {
            self.kind = kind
            self.conversationId = conversationId
            self.isOn = isOn
        }
    }

    public init(
        initial: [Enablement] = [],
        initialAlwaysConfirm: [AlwaysConfirmInitial] = []
    ) {
        self.enablements = Set(initial)
        var dict: [AlwaysConfirmKey: Bool] = [:]
        for entry in initialAlwaysConfirm where entry.isOn {
            dict[AlwaysConfirmKey(kind: entry.kind, conversationId: entry.conversationId)] = true
        }
        self.alwaysConfirm = dict
    }

    public func isEnabled(kind: ConnectionKind, capability: ConnectionCapability, conversationId: String) async -> Bool {
        enablements.contains(Enablement(kind: kind, capability: capability, conversationId: conversationId))
    }

    public func setEnabled(_ enabled: Bool, kind: ConnectionKind, capability: ConnectionCapability, conversationId: String) async {
        let enablement = Enablement(kind: kind, capability: capability, conversationId: conversationId)
        if enabled {
            enablements.insert(enablement)
        } else {
            enablements.remove(enablement)
        }
    }

    public func conversationIds(enabledFor kind: ConnectionKind, capability: ConnectionCapability) async -> [String] {
        enablements
            .filter { $0.kind == kind && $0.capability == capability }
            .map(\.conversationId)
            .sorted()
    }

    public func allEnablements() async -> [Enablement] {
        enablements.sorted(by: { lhs, rhs in
            if lhs.kind.rawValue != rhs.kind.rawValue {
                return lhs.kind.rawValue < rhs.kind.rawValue
            }
            if lhs.capability.rawValue != rhs.capability.rawValue {
                return lhs.capability.rawValue < rhs.capability.rawValue
            }
            return lhs.conversationId < rhs.conversationId
        })
    }

    public func alwaysConfirmWrites(kind: ConnectionKind, conversationId: String) async -> Bool {
        alwaysConfirm[AlwaysConfirmKey(kind: kind, conversationId: conversationId)] ?? false
    }

    public func setAlwaysConfirmWrites(_ alwaysConfirm: Bool, kind: ConnectionKind, conversationId: String) async {
        let key = AlwaysConfirmKey(kind: kind, conversationId: conversationId)
        if alwaysConfirm {
            self.alwaysConfirm[key] = true
        } else {
            self.alwaysConfirm.removeValue(forKey: key)
        }
    }
}
