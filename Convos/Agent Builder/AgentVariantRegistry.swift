import ConvosCore
import SwiftUI

/// App-lifetime cache of the dev variant registry (`GET /v2/agent-variants`).
///
/// The fetch deliberately does not live in a view's `.task`: the debug picker
/// and the new-convo picker both sit inside a `Form`/sheet whose rows are
/// recreated as state changes, which cancels an in-flight view-scoped task and
/// restarts it from a fresh `.loading` -- a loop that never settles. Holding the
/// load here means view churn re-reads a cached result instead of refetching.
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

    private var loadTask: Task<Void, Never>?
    private let apiClient: any ConvosAPIClientProtocol

    init(apiClient: any ConvosAPIClientProtocol = ConvosAPIClientFactory.client(environment: ConfigManager.shared.currentEnvironment)) {
        self.apiClient = apiClient
    }

    /// Loads once and caches. Re-entrant: concurrent callers await the same
    /// task, and an already-loaded registry returns immediately.
    func loadIfNeeded() async {
        if loadState == .loaded { return }
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

    /// Drops a persisted selection whose slug no longer exists in the live
    /// registry, so a retired variant can't silently keep routing builds.
    private func reconcileSelection(against fetched: [ConvosAPI.AgentVariant]) {
        guard let slug = FeatureFlags.shared.selectedAgentVariant?.slug else { return }
        guard !fetched.contains(where: { $0.slug == slug }) else { return }
        FeatureFlags.shared.selectedAgentVariant = nil
    }
}
