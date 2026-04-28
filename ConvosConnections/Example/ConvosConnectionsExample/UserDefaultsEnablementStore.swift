import ConvosConnections
import Foundation

/// `EnablementStore` backed by `UserDefaults`. Keeps per-(connection, capability, conversation)
/// toggle state and the per-(connection, conversation) always-confirm flag across app
/// relaunches so users don't have to re-toggle every session.
///
/// The example app uses this instead of `InMemoryEnablementStore` so toggle state survives
/// backgrounding, relaunches, and reinstalls with the same bundle id.
final class UserDefaultsEnablementStore: EnablementStore, @unchecked Sendable {
    private struct PersistedShape: Codable {
        var enablements: [Enablement]
        var alwaysConfirm: [AlwaysConfirmEntry]
    }

    private struct AlwaysConfirmEntry: Codable, Hashable {
        let kind: ConnectionKind
        let conversationId: String
    }

    private let defaults: UserDefaults
    private let key: String
    private let lock: NSLock = NSLock()

    init(defaults: UserDefaults = .standard, key: String = "ConvosConnectionsExample.enablements.v2") {
        self.defaults = defaults
        self.key = key
    }

    func isEnabled(kind: ConnectionKind, capability: ConnectionCapability, conversationId: String) async -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return read().enablements.contains(Enablement(kind: kind, capability: capability, conversationId: conversationId))
    }

    func setEnabled(_ enabled: Bool, kind: ConnectionKind, capability: ConnectionCapability, conversationId: String) async {
        lock.lock()
        defer { lock.unlock() }
        var shape = read()
        var enablementSet = Set(shape.enablements)
        let enablement = Enablement(kind: kind, capability: capability, conversationId: conversationId)
        if enabled {
            enablementSet.insert(enablement)
        } else {
            enablementSet.remove(enablement)
        }
        shape.enablements = enablementSet.sorted(by: { lhs, rhs in
            if lhs.kind.rawValue != rhs.kind.rawValue { return lhs.kind.rawValue < rhs.kind.rawValue }
            if lhs.capability.rawValue != rhs.capability.rawValue { return lhs.capability.rawValue < rhs.capability.rawValue }
            return lhs.conversationId < rhs.conversationId
        })
        write(shape)
    }

    func conversationIds(enabledFor kind: ConnectionKind, capability: ConnectionCapability) async -> [String] {
        lock.lock()
        defer { lock.unlock() }
        return read().enablements
            .filter { $0.kind == kind && $0.capability == capability }
            .map(\.conversationId)
            .sorted()
    }

    func allEnablements() async -> [Enablement] {
        lock.lock()
        defer { lock.unlock() }
        return read().enablements
    }

    func alwaysConfirmWrites(kind: ConnectionKind, conversationId: String) async -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return read().alwaysConfirm.contains(AlwaysConfirmEntry(kind: kind, conversationId: conversationId))
    }

    func setAlwaysConfirmWrites(_ alwaysConfirm: Bool, kind: ConnectionKind, conversationId: String) async {
        lock.lock()
        defer { lock.unlock() }
        var shape = read()
        var alwaysConfirmSet = Set(shape.alwaysConfirm)
        let entry = AlwaysConfirmEntry(kind: kind, conversationId: conversationId)
        if alwaysConfirm {
            alwaysConfirmSet.insert(entry)
        } else {
            alwaysConfirmSet.remove(entry)
        }
        shape.alwaysConfirm = alwaysConfirmSet.sorted(by: { lhs, rhs in
            if lhs.kind.rawValue != rhs.kind.rawValue { return lhs.kind.rawValue < rhs.kind.rawValue }
            return lhs.conversationId < rhs.conversationId
        })
        write(shape)
    }

    /// Caller must hold `lock`.
    private func read() -> PersistedShape {
        guard let data = defaults.data(forKey: key),
              let decoded = try? JSONDecoder().decode(PersistedShape.self, from: data) else {
            return PersistedShape(enablements: [], alwaysConfirm: [])
        }
        return decoded
    }

    /// Caller must hold `lock`.
    private func write(_ shape: PersistedShape) {
        guard let data = try? JSONEncoder().encode(shape) else { return }
        defaults.set(data, forKey: key)
    }
}
