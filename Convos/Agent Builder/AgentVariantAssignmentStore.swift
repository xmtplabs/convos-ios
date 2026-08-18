import ConvosCore
import Foundation

/// Remembers which variant each conversation's agents were built under.
///
/// The pick is made at new-convo creation, before a conversation id exists, so
/// it lands in `pendingSlug` first and the conversation claims it on its first
/// agent join (`claimPendingSlug(for:)`). Every later join in that same
/// conversation reads the stored assignment, so a convo keeps one variant for
/// its lifetime instead of following the global default as it changes.
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

    /// The variant chosen for the conversation about to be created, consumed by
    /// the first agent join that follows.
    var pendingSlug: String? {
        get { defaults.string(forKey: Constant.pendingSlugKey) }
        set {
            guard let newValue else {
                defaults.removeObject(forKey: Constant.pendingSlugKey)
                return
            }
            defaults.set(newValue, forKey: Constant.pendingSlugKey)
        }
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

    /// Binds any pending pick to this conversation and clears it, so the next
    /// conversation starts from the default rather than inheriting this one's.
    /// Returns the slug now in force for the conversation (existing assignment
    /// wins, so a re-join can't be re-pointed by a later pending pick).
    @discardableResult
    func claimPendingSlug(for conversationId: String) -> String? {
        guard !conversationId.isEmpty else { return nil }
        if let existing = slug(for: conversationId) {
            pendingSlug = nil
            return existing
        }
        guard let pending = pendingSlug else { return nil }
        assign(slug: pending, to: conversationId)
        pendingSlug = nil
        Log.info("AgentVariant: conversation \(conversationId) claimed variant \(pending)")
        return pending
    }

    private func assignments() -> [String: String] {
        defaults.dictionary(forKey: Constant.assignmentsKey) as? [String: String] ?? [:]
    }

    private enum Constant {
        static let assignmentsKey: String = "agentVariantAssignmentsByConversation"
        static let pendingSlugKey: String = "agentVariantPendingSlug"
    }
}
