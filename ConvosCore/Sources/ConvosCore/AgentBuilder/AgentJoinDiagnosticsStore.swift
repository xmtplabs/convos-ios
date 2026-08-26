import Foundation

/// The backend-confirmed routing result for one direct agent join. This is a
/// dev diagnostic only: it records no credentials or message content, and is
/// keyed by conversation so an unrelated later join cannot overwrite the Doc
/// shell's result.
public struct AgentJoinDiagnostic: Codable, Sendable, Equatable {
    public let conversationId: String
    public let requestedVariantId: String?
    public let variant: ConvosAPI.AgentJoinResponse.Variant?
    public let variantDropped: Bool?
    public let recordedAt: Date

    public init(
        conversationId: String,
        requestedVariantId: String?,
        variant: ConvosAPI.AgentJoinResponse.Variant?,
        variantDropped: Bool?,
        recordedAt: Date = Date()
    ) {
        self.conversationId = conversationId
        self.requestedVariantId = requestedVariantId
        self.variant = variant
        self.variantDropped = variantDropped
        self.recordedAt = recordedAt
    }
}

public extension Notification.Name {
    static let agentJoinDiagnosticsDidChange: Notification.Name = Notification.Name(
        "org.convos.agentJoinDiagnosticsDidChange"
    )
}

/// A tiny persisted, thread-safe diagnostic cache shared by the API client and
/// the Debug screen. UserDefaults keeps the latest result visible across a
/// relaunch, which is when a tester most needs to understand a bad binding.
public final class AgentJoinDiagnosticsStore: @unchecked Sendable {
    public static let shared: AgentJoinDiagnosticsStore = AgentJoinDiagnosticsStore()

    private let defaults: UserDefaults
    private let lock: NSLock = NSLock()
    private let storageKey: String = "agentJoinDiagnostics.v1"

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    public func diagnostic(for conversationId: String) -> AgentJoinDiagnostic? {
        guard !conversationId.isEmpty else { return nil }
        return lock.withLock { diagnostics()[normalized(conversationId)] }
    }

    public func record(
        conversationId: String,
        requestedVariantId: String?,
        response: ConvosAPI.AgentJoinResponse
    ) {
        guard !conversationId.isEmpty else { return }
        let diagnostic = AgentJoinDiagnostic(
            conversationId: conversationId,
            requestedVariantId: requestedVariantId,
            variant: response.variant,
            variantDropped: response.variantDropped
        )
        lock.withLock {
            var stored = diagnostics()
            stored[normalized(conversationId)] = diagnostic
            persist(stored)
        }
        NotificationCenter.default.post(name: .agentJoinDiagnosticsDidChange, object: conversationId)
    }

    public func clear(conversationId: String) {
        guard !conversationId.isEmpty else { return }
        lock.withLock {
            var stored = diagnostics()
            stored[normalized(conversationId)] = nil
            persist(stored)
        }
        NotificationCenter.default.post(name: .agentJoinDiagnosticsDidChange, object: conversationId)
    }

    private func normalized(_ conversationId: String) -> String {
        conversationId.lowercased()
    }

    private func diagnostics() -> [String: AgentJoinDiagnostic] {
        guard let data = defaults.data(forKey: storageKey) else { return [:] }
        return (try? JSONDecoder().decode([String: AgentJoinDiagnostic].self, from: data)) ?? [:]
    }

    private func persist(_ diagnostics: [String: AgentJoinDiagnostic]) {
        guard let data = try? JSONEncoder().encode(diagnostics) else { return }
        defaults.set(data, forKey: storageKey)
    }
}
