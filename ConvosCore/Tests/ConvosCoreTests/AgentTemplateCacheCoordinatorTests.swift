@testable import ConvosCore
import Foundation
import GRDB
import os
import Testing

/// Direct lifecycle coverage for `AgentTemplateCacheCoordinator`: observing an
/// uncached agent contact fetches + caches its template exactly once, and
/// `stop()` halts observation so a later contact change does not fetch. A true
/// start/stop interleaving race is not deterministically reproducible; this
/// guards the observable contract the lock fix in `start()` protects.
@Suite("AgentTemplateCacheCoordinator", .serialized)
struct AgentTemplateCacheCoordinatorTests {
    /// Stub API client that records each template fetch (thread-safe; fetches
    /// run on the coordinator's observation task).
    private final class CountingTemplateAPIClient: TestStubAPIClient, @unchecked Sendable {
        private let calls: OSAllocatedUnfairLock<[String]> = .init(initialState: [])
        var fetchedIds: [String] { calls.withLock { $0 } }
        var count: Int { calls.withLock { $0.count } }

        override func getAgentTemplate(idOrUrlSlug: String) async throws -> ConvosAPI.AgentTemplate {
            calls.withLock { $0.append(idOrUrlSlug) }
            return ConvosAPI.AgentTemplate(
                id: idOrUrlSlug,
                status: "published",
                publishedUrl: nil,
                slug: nil,
                agentName: "Agent \(idOrUrlSlug)",
                description: nil,
                emoji: "🤖",
                avatarUrl: nil
            )
        }
    }

    private func insertAgentContact(_ db: Database, inboxId: String, templateId: String) throws {
        try DBContact(
            inboxId: inboxId,
            addedAt: Date(),
            addedViaConversationId: nil,
            agentVerification: .verified(.convos),
            agentTemplateId: templateId
        ).insert(db)
    }

    /// Returns true as soon as `condition` holds, or false at `timeout`.
    private func waitUntil(_ timeout: Duration, _ condition: () -> Bool) async -> Bool {
        let deadline = ContinuousClock.now.advanced(by: max(timeout, .seconds(30)) * testTimeoutScale)
        while ContinuousClock.now < deadline {
            if condition() { return true }
            try? await Task.sleep(for: .milliseconds(25))
        }
        return condition()
    }

    @Test("fetches an uncached template once on start, and stop() halts observation")
    func observesThenStops() async throws {
        let dbManager = MockDatabaseManager.makeTestDatabase()
        let apiClient = CountingTemplateAPIClient()
        let cacheWriter = AgentTemplateCacheWriter(databaseWriter: dbManager.dbWriter)
        let coordinator = AgentTemplateCacheCoordinator(
            databaseReader: dbManager.dbReader,
            apiClient: apiClient,
            cacheWriter: cacheWriter
        )

        try await dbManager.dbWriter.write { db in
            try self.insertAgentContact(db, inboxId: "agent-a", templateId: "tmpl-1")
        }

        coordinator.start()

        // Generous timeout: the coordinator observes on a detached task, which
        // the cooperative pool can starve for several seconds in the integration
        // job (it runs alongside the network-bound suite). Mirrors the headroom
        // in AgentTemplateRepositoryTests; it returns the instant the fetch lands.
        let fetchedFirst = await waitUntil(.seconds(20)) { apiClient.fetchedIds.contains("tmpl-1") }
        #expect(fetchedFirst, "start() should fetch the uncached template")

        coordinator.stop()
        let countAfterStop = apiClient.count

        // A contact change after stop() must not be observed - so no new fetch.
        try await dbManager.dbWriter.write { db in
            try self.insertAgentContact(db, inboxId: "agent-b", templateId: "tmpl-2")
        }
        try await Task.sleep(for: .seconds(2))

        #expect(apiClient.count == countAfterStop)
        #expect(!apiClient.fetchedIds.contains("tmpl-2"), "stop() should halt observation")

        coordinator.stop()
    }

    /// Stub API client that always fails template fetches with a fixed error.
    private final class FailingTemplateAPIClient: TestStubAPIClient, @unchecked Sendable {
        private let calls: OSAllocatedUnfairLock<[String]> = .init(initialState: [])
        private let error: any Error
        var count: Int { calls.withLock { $0.count } }

        init(throwing error: any Error) {
            self.error = error
        }

        override func getAgentTemplate(idOrUrlSlug: String) async throws -> ConvosAPI.AgentTemplate {
            calls.withLock { $0.append(idOrUrlSlug) }
            throw error
        }
    }

    @Test("a 404ed template is never refetched, even as contact writes re-fire the observation")
    func notFoundIsPermanent() async throws {
        let dbManager = MockDatabaseManager.makeTestDatabase()
        let apiClient = FailingTemplateAPIClient(throwing: APIError.notFound)
        let cacheWriter = AgentTemplateCacheWriter(databaseWriter: dbManager.dbWriter)
        let coordinator = AgentTemplateCacheCoordinator(
            databaseReader: dbManager.dbReader,
            apiClient: apiClient,
            cacheWriter: cacheWriter,
            retryCooldown: 0
        )

        try await dbManager.dbWriter.write { db in
            try self.insertAgentContact(db, inboxId: "agent-a", templateId: "tmpl-deleted")
        }

        coordinator.start()

        let fetchedOnce = await waitUntil(.seconds(20)) { apiClient.count >= 1 }
        #expect(fetchedOnce, "the first observation should attempt the fetch")

        // A contact write re-fires the observation with the same uncached id;
        // the 404 memory must keep it from refetching. Cooldown is zero, so
        // only the deleted-template set can be responsible for the skip.
        try await dbManager.dbWriter.write { db in
            try self.insertAgentContact(db, inboxId: "agent-b", templateId: "tmpl-deleted")
        }
        try await Task.sleep(for: .seconds(2))

        #expect(apiClient.count == 1, "a deleted template must not be refetched")
        coordinator.stop()
    }

    @Test("a transiently failing template is skipped while its cooldown is running")
    func transientFailureCoolsDown() async throws {
        let dbManager = MockDatabaseManager.makeTestDatabase()
        let apiClient = FailingTemplateAPIClient(throwing: APIError.serverError(nil))
        let cacheWriter = AgentTemplateCacheWriter(databaseWriter: dbManager.dbWriter)
        let coordinator = AgentTemplateCacheCoordinator(
            databaseReader: dbManager.dbReader,
            apiClient: apiClient,
            cacheWriter: cacheWriter,
            retryCooldown: 3600
        )

        try await dbManager.dbWriter.write { db in
            try self.insertAgentContact(db, inboxId: "agent-a", templateId: "tmpl-flaky")
        }

        coordinator.start()

        let fetchedOnce = await waitUntil(.seconds(20)) { apiClient.count >= 1 }
        #expect(fetchedOnce, "the first observation should attempt the fetch")

        try await dbManager.dbWriter.write { db in
            try self.insertAgentContact(db, inboxId: "agent-b", templateId: "tmpl-flaky")
        }
        try await Task.sleep(for: .seconds(2))

        #expect(apiClient.count == 1, "a transient failure must not be retried within its cooldown")
        coordinator.stop()
    }

    @Test("a transiently failing template is retried once its cooldown has elapsed")
    func transientFailureRetriesAfterCooldown() async throws {
        let dbManager = MockDatabaseManager.makeTestDatabase()
        let apiClient = FailingTemplateAPIClient(throwing: APIError.serverError(nil))
        let cacheWriter = AgentTemplateCacheWriter(databaseWriter: dbManager.dbWriter)
        let coordinator = AgentTemplateCacheCoordinator(
            databaseReader: dbManager.dbReader,
            apiClient: apiClient,
            cacheWriter: cacheWriter,
            retryCooldown: 0
        )

        try await dbManager.dbWriter.write { db in
            try self.insertAgentContact(db, inboxId: "agent-a", templateId: "tmpl-flaky")
        }

        coordinator.start()

        let fetchedOnce = await waitUntil(.seconds(20)) { apiClient.count >= 1 }
        #expect(fetchedOnce, "the first observation should attempt the fetch")

        // With a zero cooldown the next observation fire may retry the id.
        try await dbManager.dbWriter.write { db in
            try self.insertAgentContact(db, inboxId: "agent-b", templateId: "tmpl-flaky")
        }

        let retried = await waitUntil(.seconds(20)) { apiClient.count >= 2 }
        #expect(retried, "an elapsed cooldown must allow the retry")
        coordinator.stop()
    }
}
