import Foundation
import GRDB
import os

/// Keeps the `DBAgentTemplate` read-through cache populated: observes the
/// contact table for the distinct template ids carried by agent contacts
/// and, for any not yet cached, fetches the canonical template identity
/// (name / emoji / avatar) from `GET /api/v2/agent-templates/{id}` and
/// upserts it. This is what lets the contacts list collapse a template's
/// running instances into one row with a stable, canonical identity rather
/// than per-instance profile data.
///
/// Session-scoped (captures the live API client); started/stopped by
/// `SyncingManager`. Convergent: upserting a fetched template mutates the
/// `agentTemplate` table, which the observation tracks, so the id drops out
/// of the "uncached" set and the loop settles. Single-flight per id avoids
/// duplicate fetches while one is in flight.
///
/// `@unchecked Sendable` for the same reason as `SyncClientParams`: the
/// captured API client is thread-safe, and the only mutable state is
/// guarded by unfair locks.
final class AgentTemplateCacheCoordinator: @unchecked Sendable {
    private let databaseReader: any DatabaseReader
    private let apiClient: any ConvosAPIClientProtocol
    private let cacheWriter: any AgentTemplateCacheWriterProtocol

    private let observationTask: OSAllocatedUnfairLock<Task<Void, Never>?> = .init(initialState: nil)
    private let inflight: OSAllocatedUnfairLock<Set<String>> = .init(initialState: [])

    init(
        databaseReader: any DatabaseReader,
        apiClient: any ConvosAPIClientProtocol,
        cacheWriter: any AgentTemplateCacheWriterProtocol
    ) {
        self.databaseReader = databaseReader
        self.apiClient = apiClient
        self.cacheWriter = cacheWriter
    }

    /// Begin observing. Safe to call repeatedly - the previous task is
    /// cancelled and replaced.
    func start() {
        let new: Task<Void, Never> = Task { [weak self] in
            await self?.observe()
        }
        observationTask.withLock { existing in
            existing?.cancel()
            existing = new
        }
    }

    func stop() {
        observationTask.withLock { existing in
            existing?.cancel()
            existing = nil
        }
    }

    private func observe() async {
        let dbReader = databaseReader
        let stream = ValueObservation
            .tracking { db in
                try Self.fetchUncachedTemplateIds(db: db)
            }
            .values(in: dbReader)
        do {
            for try await templateIds in stream {
                if Task.isCancelled { return }
                for templateId in templateIds {
                    if Task.isCancelled { return }
                    await fetchAndCache(templateId)
                }
            }
        } catch {
            Log.error("AgentTemplateCacheCoordinator: stream failed: \(error.localizedDescription)")
        }
    }

    /// Distinct template ids referenced by agent contacts that aren't in the
    /// cache yet. Tracking this re-fires on both `contact` and
    /// `agentTemplate` changes, so a successful upsert removes the id and
    /// the observation converges.
    static func fetchUncachedTemplateIds(db: Database) throws -> [String] {
        try String.fetchAll(db, sql: """
            SELECT DISTINCT contact.agentTemplateId FROM contact
            WHERE contact.agentTemplateId IS NOT NULL
              AND contact.agentTemplateId NOT IN (SELECT templateId FROM agentTemplate)
            """)
    }

    private func fetchAndCache(_ templateId: String) async {
        let claimed: Bool = inflight.withLock { active in
            if active.contains(templateId) { return false }
            active.insert(templateId)
            return true
        }
        guard claimed else { return }
        defer {
            inflight.withLock { active in active.remove(templateId) }
        }
        do {
            let template = try await apiClient.getAgentTemplate(idOrUrlSlug: templateId)
            try await cacheWriter.upsert(template, fetchedAt: Date())
        } catch {
            Log.warning("AgentTemplateCacheCoordinator: fetch failed for \(templateId): \(error.localizedDescription)")
        }
    }
}
