import Foundation

/// Content a targetless share staged for the agent builder.
///
/// The share extension can't host the agent-builder flow (its commit path
/// polls a 30-60s generation, longer than any extension runway, and its
/// capability OAuth needs the app). Instead the extension stages the shared
/// content here and the app opens the builder pre-seeded on its next
/// foreground.
public struct PendingAgentBuilderShare: Codable, Sendable {
    public let text: String
    /// Filenames inside the shared sent-photos cache
    /// (`PhotoAttachmentService.localCacheURL(for:)` resolves them).
    public let attachmentFilenames: [String]
    public let createdAt: Date

    public init(text: String, attachmentFilenames: [String], createdAt: Date = Date()) {
        self.text = text
        self.attachmentFilenames = attachmentFilenames
        self.createdAt = createdAt
    }
}

/// App-group UserDefaults handoff between the share extension (writer) and
/// the main app (consumer).
public enum AgentBuilderShareHandoff {
    public static func stage(_ share: PendingAgentBuilderShare, appGroupIdentifier: String) {
        guard let defaults = UserDefaults(suiteName: appGroupIdentifier),
              let encoded = try? JSONEncoder().encode(share) else {
            Log.error("Failed to stage agent-builder share")
            return
        }
        defaults.set(encoded, forKey: Constant.key)
    }

    /// Returns the pending share and clears it. Stale records (the user never
    /// came back) are dropped rather than surfacing a surprise builder days
    /// later.
    public static func consume(appGroupIdentifier: String) -> PendingAgentBuilderShare? {
        guard let defaults = UserDefaults(suiteName: appGroupIdentifier),
              let encoded = defaults.data(forKey: Constant.key) else {
            return nil
        }
        defaults.removeObject(forKey: Constant.key)
        guard let share = try? JSONDecoder().decode(PendingAgentBuilderShare.self, from: encoded),
              Date().timeIntervalSince(share.createdAt) < Constant.maxAge else {
            return nil
        }
        return share
    }

    private enum Constant {
        static let key: String = "agentBuilderShare.pending"
        static let maxAge: TimeInterval = 24 * 60 * 60
    }
}
