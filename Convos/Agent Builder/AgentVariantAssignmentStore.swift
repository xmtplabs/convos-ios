import ConvosCore
import Foundation

/// Remembers which variant each conversation's agents were built under.
///
/// The pick is made at new-convo creation, before a conversation id exists, so
/// it rides along on the `NewConversationViewModel` that mints the
/// conversation and is written here once that flow reaches `.ready` with an id.
/// Deliberately not a single shared "pending" slot: two overlapping creation
/// flows would race for it, and the second pick would bind to the first
/// conversation. Every later join in a conversation reads its assignment, so a
/// convo keeps one variant for its lifetime instead of following the global
/// default as it changes.
///
/// Backed by UserDefaults rather than the database: this is a dev-only testing
/// aid gated behind `FeatureFlags.isAgentVariantSelectorEnabled`, and a schema
/// migration would be disproportionate for it.
@MainActor
final class AgentVariantAssignmentStore {
    static let shared: AgentVariantAssignmentStore = AgentVariantAssignmentStore()

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    func slug(for conversationId: String) -> String? {
        guard !conversationId.isEmpty else { return nil }
        return assignments()[conversationId]
    }

    func assign(slug: String?, to conversationId: String) {
        guard !conversationId.isEmpty else { return }
        var current = assignments()
        if let slug {
            current[conversationId] = slug
        } else {
            current.removeValue(forKey: conversationId)
        }
        defaults.set(current, forKey: Constant.assignmentsKey)
    }

    /// Records the variant a freshly created conversation was started under.
    /// An existing assignment wins, so a conversation that already routed a
    /// join can't be re-pointed later.
    func assignIfUnset(slug: String?, to conversationId: String) {
        guard let slug, !conversationId.isEmpty else { return }
        guard self.slug(for: conversationId) == nil else { return }
        assign(slug: slug, to: conversationId)
        Log.info("AgentVariant: conversation \(conversationId) bound to variant \(slug)")
    }

    private func assignments() -> [String: String] {
        defaults.dictionary(forKey: Constant.assignmentsKey) as? [String: String] ?? [:]
    }

    private enum Constant {
        static let assignmentsKey: String = "agentVariantAssignmentsByConversation"
    }
}
