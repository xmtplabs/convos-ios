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
/// Failed fetches need their own convergence path because a failed id never
/// enters the cache: without memory, every contact-table write re-fires the
/// observation and refetches the same doomed ids (observed in the field as
/// ~90 requests/minute for templates that had been deleted on the backend).
/// A 404 marks the id as deleted for this coordinator's lifetime; any other
/// failure starts a cooldown before that id is attempted again.
///
/// `@unchecked Sendable` for the same reason as `SyncClientParams`: the
/// captured API client is thread-safe, and the only mutable state is
/// guarded by unfair locks.
final class AgentTemplateCacheCoordinator: @unchecked Sendable {
    private let databaseReader: any DatabaseReader
    private let apiClient: any ConvosAPIClientProtocol
    private let cacheWriter: any AgentTemplateCacheWriterProtocol
    private let retryCooldown: TimeInterval

    private let observationTask: OSAllocatedUnfairLock<Task<Void, Never>?> = .init(initialState: nil)
    private let inflight: OSAllocatedUnfairLock<Set<String>> = .init(initialState: [])
    /// Ids whose fetch 404ed: the template was deleted on the backend, so
    /// the contact rows referencing it can never resolve. Never retried for
    /// this coordinator's lifetime (a restart gets one fresh attempt).
    private let deletedTemplateIds: OSAllocatedUnfairLock<Set<String>> = .init(initialState: [])
    /// Most recent failed attempt per id, for transient failures (network,
    /// server errors). The id is skipped until `retryCooldown` has elapsed.
    private let failedAttempts: OSAllocatedUnfairLock<[String: Date]> = .init(initialState: [:])

    init(
        databaseReader: any DatabaseReader,
        apiClient: any ConvosAPIClientProtocol,
        cacheWriter: any AgentTemplateCacheWriterProtocol,
        retryCooldown: TimeInterval = 300
    ) {
        self.databaseReader = databaseReader
        self.apiClient = apiClient
        self.cacheWriter = cacheWriter
        self.retryCooldown = retryCooldown
    }

    /// Begin observing. Safe to call repeatedly - the previous task is
    /// cancelled and replaced.
    func start() {
        observationTask.withLock { existing in
            existing?.cancel()
            existing = Task { [weak self] in
                await self?.observe()
            }
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
                for templateId in templateIds where shouldAttemptFetch(templateId) {
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

    private func shouldAttemptFetch(_ templateId: String) -> Bool {
        if deletedTemplateIds.withLock({ $0.contains(templateId) }) {
            return false
        }
        let lastFailure: Date? = failedAttempts.withLock { $0[templateId] }
        guard let lastFailure else { return true }
        return Date().timeIntervalSince(lastFailure) >= retryCooldown
    }

    private func fetchAndCache(_ templateId: String) async {
        let claimed: Bool = inflight.withLock { active in
            if active.contains(templateId) { return false }
            active.insert(templateId)
            return true
        }
        guard claimed else { return }
        defer {
            _ = inflight.withLock { active in active.remove(templateId) }
        }
        do {
            let template = try await apiClient.getAgentTemplate(idOrUrlSlug: templateId)
            try await cacheWriter.upsert(template, fetchedAt: Date())
            _ = failedAttempts.withLock { $0.removeValue(forKey: templateId) }
        } catch APIError.notFound {
            _ = deletedTemplateIds.withLock { $0.insert(templateId) }
            Log.warning("AgentTemplateCacheCoordinator: template \(templateId) not found; not retrying")
        } catch {
            failedAttempts.withLock { $0[templateId] = Date() }
            Log.warning("AgentTemplateCacheCoordinator: fetch failed for \(templateId): \(error.localizedDescription)")
        }
    }
}
