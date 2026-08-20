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

extension ConversationReadyResult.Origin {
    /// Whether a creation flow's variant pick belongs to the conversation it
    /// just settled on.
    ///
    /// `.created` is the cold path — the flow minted the conversation. But the
    /// common path is `.existing`: compose adopts a conversation prepared ahead
    /// of the pick (`prepareNewConversation()`), and that row is just as much
    /// this flow's own. Binding only on `.created` dropped the pick on every
    /// warm-cache create, and the join then read the global selector — usually
    /// nothing — so the agent quietly built on the default runtime.
    ///
    /// Only `.joined` is somebody else's conversation, superseding the one this
    /// flow was going to create; the pick was never made for it. Invite and
    /// scanner flows carry no pick at all (`agentVariantSlug` is nil), so they
    /// stay unbound regardless of which origin they report.
    var bindsCreationFlowVariantPick: Bool {
        switch self {
        case .created, .existing: return true
        case .joined: return false
        }
    }
}

/// The one place that answers "which variant does this conversation's agent
/// traffic route to". Every caller — the join, the join-status poll, the
/// participation read and mirror, and the warm-cache default-agent provision —
/// resolves through here, so none of them can drift onto the global selector
/// while the others read the conversation's own binding.
@MainActor
enum AgentVariantResolution {
    static func slug(for conversationId: String) -> String? {
        guard !ConfigManager.shared.currentEnvironment.isProduction else {
            return FeatureFlags.shared.effectiveAgentVariantSlug
        }
        if let assigned = AgentVariantAssignmentStore.shared.slug(for: conversationId) {
            Log.info("AgentVariant: \(conversationId) routing to assigned variant \(assigned)")
            return assigned
        }
        let fallback = FeatureFlags.shared.effectiveAgentVariantSlug
        Log.info("AgentVariant: \(conversationId) has no assignment, using \(fallback ?? "none")")
        return fallback
    }
}
