import ConvosCore
import Foundation
import Observation

/// Stable id for the trailing "Suggested agents" section, shared by the
/// contacts browser and the picker so each can swap in the section's custom
/// header (see `SuggestedAgentsSectionHeader`).
enum SuggestedAgentsSection {
    static let id: String = "suggested-agents"
    static let title: String = "Suggested agents"
}

/// Shared fetch + pagination state for the "Suggested agents" section. Owned
/// by both `ContactsViewModel` (the Contacts tab) and `ContactsPickerViewModel`
/// (the compose picker) so the section behaves identically across every
/// contacts list. Pulls featured agent templates a page at a time; the host
/// turns `agents` into rows -- de-duping against the contacts it already shows
/// -- and rebuilds its sections from the `onAgentsChanged` callback.
@Observable
@MainActor
final class SuggestedAgentsModel {
    private let service: (any SuggestedAgentsServiceProtocol)?
    private let pageSize: Int

    private(set) var agents: [SuggestedAgent] = []
    private(set) var isLoading: Bool = false

    private var cursor: String?
    private var hasMore: Bool = true
    private var seenTemplateIds: Set<String> = []

    /// Invoked on the main actor whenever `agents` changes so the host can
    /// rebuild its sections.
    var onAgentsChanged: (() -> Void)?

    init(service: (any SuggestedAgentsServiceProtocol)?, pageSize: Int = 20) {
        self.service = service
        self.pageSize = pageSize
    }

    /// True when a service is wired and the section should participate.
    var isActive: Bool {
        service != nil
    }

    /// Loads (or refreshes) the first page. Called from `.task` on appear, so
    /// re-opening the surface picks up newly-featured agents. The in-flight
    /// guard in `fetch` collapses overlapping appears into a single request,
    /// and the page is swapped in only once it arrives (no clear-then-flicker).
    func loadIfNeeded() async {
        await fetch(cursor: nil, reset: true)
    }

    /// Loads the next page when the last suggested row scrolls into view,
    /// until the backend reports there are no more.
    func loadMore() async {
        guard hasMore, !isLoading, let cursor else { return }
        await fetch(cursor: cursor, reset: false)
    }

    private func fetch(cursor: String?, reset: Bool) async {
        guard let service, !isLoading else { return }
        isLoading = true
        defer { isLoading = false }
        do {
            let page = try await service.featuredAgents(limit: pageSize, cursor: cursor)
            if reset {
                agents = []
                seenTemplateIds = []
            }
            for agent in page.agents {
                guard seenTemplateIds.insert(agent.templateId).inserted else { continue }
                agents.append(agent)
            }
            self.cursor = page.nextCursor
            hasMore = page.nextCursor != nil
            onAgentsChanged?()
        } catch {
            Log.error("Failed loading suggested agents: \(error.localizedDescription)")
            // Stop advertising more only when the first page fails; a failed
            // load-more leaves the cursor in place so a later scroll retries.
            if reset {
                hasMore = false
            }
        }
    }
}

extension SuggestedAgentsModel {
    /// Synthetic contacts for the agents not already present as contacts,
    /// preserving fetch order. The host passes the template ids it already
    /// renders so an agent never shows in both the alphabetical list and the
    /// suggested section.
    func visibleAgents(excludingTemplateIds excluded: Set<String>) -> [SuggestedAgent] {
        agents.filter { !excluded.contains($0.templateId) }
    }
}
