import ConvosCore
import SwiftUI

/// Short-lived cache of the dev variant registry (`GET /v2/agent-variants`).
///
/// The fetch deliberately does not live in a view's `.task`: the debug picker
/// and the new-convo picker both sit inside a `Form`/sheet whose rows are
/// recreated as state changes, which cancels an in-flight view-scoped task and
/// restarts it from a fresh `.loading` -- a loop that never settles. Holding the
/// load here means view churn re-reads a cached result instead of refetching.
///
/// The cache expires, because a variant is usually registered minutes before
/// someone goes looking for it. Cached for the process's lifetime, a variant
/// that CI registered after this app last loaded the list is invisible until
/// the app is killed -- and worse than invisible: `reconcileSelection` and the
/// new-convo sheet both drop a selected slug that the (stale) list does not
/// contain, so the tester's pick is silently cleared and their agent quietly
/// builds on the default runtime.
@MainActor
@Observable
final class AgentVariantRegistry {
    enum LoadState: Equatable {
        case idle
        case loading
        case loaded
        case failed
    }

    static let shared: AgentVariantRegistry = AgentVariantRegistry()

    private(set) var variants: [ConvosAPI.AgentVariant] = []
    private(set) var loadState: LoadState = .idle

    /// How long a loaded list stays fresh. Long enough that Form row churn
    /// re-reads the cache rather than refetching, short enough that reopening
    /// a picker after CI registers a variant shows it.
    private static let freshnessWindow: TimeInterval = 30.0

    private var loadTask: Task<Void, Never>?
    private var loadedAt: Date?
    private let apiClient: any ConvosAPIClientProtocol

    init(apiClient: any ConvosAPIClientProtocol = ConvosAPIClientFactory.client(environment: ConfigManager.shared.currentEnvironment)) {
        self.apiClient = apiClient
    }

    /// Loads and caches for `freshnessWindow`. Re-entrant: concurrent callers
    /// await the same task, and a registry loaded within the window returns
    /// immediately. Past the window the next call refetches, so a picker opened
    /// after CI registered a variant sees it without an app restart.
    func loadIfNeeded() async {
        if loadState == .loaded, let loadedAt,
           Date().timeIntervalSince(loadedAt) < Self.freshnessWindow {
            return
        }
        // An in-flight load is awaited rather than restarted -- that guard, not
        // the absence of expiry, is what keeps view churn from looping.
        if let loadTask {
            await loadTask.value
            return
        }
        await reload()
    }

    /// Forces a refetch, replacing any cached result. Detached from the caller's
    /// task so a cancelled view teardown can't cancel the fetch itself.
    func reload() async {
        loadTask?.cancel()
        loadState = .loading
        let task = Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                let fetched = try await self.apiClient.getAgentVariants()
                self.variants = fetched
                self.reconcileSelection(against: fetched)
                self.loadedAt = Date()
                self.loadState = .loaded
            } catch {
                Log.error("AgentVariantRegistry: failed to load variants: \(error.localizedDescription)")
                self.loadState = .failed
            }
            self.loadTask = nil
        }
        loadTask = task
        await task.value
    }

    func variant(withSlug slug: String?) -> ConvosAPI.AgentVariant? {
        guard let slug else { return nil }
        return variants.first { $0.slug == slug }
    }

    /// The backend returns the registry newest-first, so the first exact label
    /// match is the most recently registered live variant for that product.
    func mostRecentlyRegisteredVariant(labeled label: String) -> ConvosAPI.AgentVariant? {
        Self.mostRecentlyRegisteredVariant(labeled: label, in: variants)
    }

    static func mostRecentlyRegisteredVariant(
        labeled label: String,
        in variants: [ConvosAPI.AgentVariant]
    ) -> ConvosAPI.AgentVariant? {
        variants.first { $0.label == label }
    }

    /// Drops a persisted selection whose slug no longer exists in the live
    /// registry, so a retired variant can't silently keep routing builds.
    private func reconcileSelection(against fetched: [ConvosAPI.AgentVariant]) {
        guard let slug = FeatureFlags.shared.selectedAgentVariant?.slug else { return }
        guard !fetched.contains(where: { $0.slug == slug }) else { return }
        FeatureFlags.shared.selectedAgentVariant = nil
    }
}

@MainActor
enum DocModeVariantResolver {
    enum Resolution: Equatable {
        case resolved(ConvosAPI.AgentVariant)
        case notRegistered
        case unavailable
    }

    static func resolve(
        registry: AgentVariantRegistry = .shared,
        forceRefresh: Bool = false
    ) async -> Resolution {
        if forceRefresh {
            await registry.reload()
        } else {
            await registry.loadIfNeeded()
        }

        guard registry.loadState == .loaded else { return .unavailable }
        guard let variant = registry.mostRecentlyRegisteredVariant(labeled: "Doc") else {
            FeatureFlags.shared.isAgentVariantSelectorEnabled = true
            FeatureFlags.shared.selectedAgentVariant = nil
            return .notRegistered
        }

        FeatureFlags.shared.isAgentVariantSelectorEnabled = true
        FeatureFlags.shared.selectedAgentVariant = variant
        return .resolved(variant)
    }
}

enum DocAgentConvergenceAction: Equatable {
    case create
    case keep
    case replace

    static func resolve(
        conversationId: String?,
        diagnostic: AgentJoinDiagnostic?,
        expectedVariantSlug: String
    ) -> Self {
        guard conversationId != nil else { return .create }
        guard let diagnostic,
              diagnostic.variantDropped != true,
              diagnostic.variant?.slug == expectedVariantSlug else {
            return .replace
        }
        return .keep
    }
}
