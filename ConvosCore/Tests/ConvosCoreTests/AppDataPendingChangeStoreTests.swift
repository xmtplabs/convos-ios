@testable import ConvosCore
import Foundation
import GRDB
import Testing

/// Contract tests for `AppDataPendingChangeStoreProtocol`, run against both
/// implementations. Covers seq assignment, same-(conversation, domain,
/// scopeKey) supersede with id reporting, readiness ordering, reschedule and
/// backoff reset, and deletion.
@Suite("AppData pending change store")
struct AppDataPendingChangeStoreTests {
    @Test("GRDB implementation satisfies the contract")
    func grdbContract() async throws {
        let queue = try DatabaseQueue()
        try await queue.write { db in
            try SharedDatabaseMigrator.createAppDataPendingChange(db)
        }
        let store = GRDBAppDataPendingChangeStore(databaseWriter: queue, databaseReader: queue)
        try await runContract(store)
    }

    @Test("in-memory implementation satisfies the contract")
    func inMemoryContract() async throws {
        try await runContract(InMemoryAppDataPendingChangeStore())
    }

    private func change(
        _ id: String,
        seq: Int64,
        conversationId: String,
        domain: String,
        scopeKey: String? = nil,
        at: Date
    ) -> DBAppDataPendingChange {
        DBAppDataPendingChange(
            id: id,
            seq: seq,
            conversationId: conversationId,
            domain: domain,
            scopeKey: scopeKey,
            snapshot: Data([0x01]),
            nextAttemptAt: at,
            createdAt: at,
            updatedAt: at
        )
    }

    private func runContract(_ store: any AppDataPendingChangeStoreProtocol) async throws {
        let past = Date(timeIntervalSince1970: 100)
        let now = Date(timeIntervalSince1970: 1_000)
        let future = Date(timeIntervalSince1970: 5_000)

        // Seq assignment is monotonic starting at 1.
        let first = try await store.enqueueNext { seq in
            self.change("A", seq: seq, conversationId: "conv-1", domain: "inviteTag", at: past)
        }
        #expect(first.inserted.seq == 1)
        #expect(first.supersededIds.isEmpty)

        // Different domain in the same conversation does not supersede.
        let second = try await store.enqueueNext { seq in
            self.change("B", seq: seq, conversationId: "conv-1", domain: "emoji", at: future)
        }
        #expect(second.inserted.seq == 2)
        #expect(second.supersededIds.isEmpty)

        // Same (conversation, domain, scopeKey) supersedes and reports the id.
        let third = try await store.enqueueNext { seq in
            self.change("C", seq: seq, conversationId: "conv-1", domain: "inviteTag", at: past)
        }
        #expect(third.inserted.seq == 3)
        #expect(third.supersededIds == ["A"])
        let aGone = try await store.rowExists(id: "A")
        #expect(aGone == false)

        // Distinct scopeKeys within one domain coexist; matching scopeKey supersedes.
        let profile1 = try await store.enqueueNext { seq in
            self.change("P1", seq: seq, conversationId: "conv-1", domain: "profile", scopeKey: "inbox-1", at: past)
        }
        #expect(profile1.supersededIds.isEmpty)
        let profile2 = try await store.enqueueNext { seq in
            self.change("P2", seq: seq, conversationId: "conv-1", domain: "profile", scopeKey: "inbox-2", at: past)
        }
        #expect(profile2.supersededIds.isEmpty)
        let profile1Again = try await store.enqueueNext { seq in
            self.change("P3", seq: seq, conversationId: "conv-1", domain: "profile", scopeKey: "inbox-1", at: past)
        }
        #expect(profile1Again.supersededIds == ["P1"])

        // Another conversation's row of the same domain is untouched.
        let other = try await store.enqueueNext { seq in
            self.change("D", seq: seq, conversationId: "conv-2", domain: "inviteTag", at: past)
        }
        #expect(other.supersededIds.isEmpty)

        // pendingChanges returns a conversation's rows in seq order.
        let conv1Rows = try await store.pendingChanges(conversationId: "conv-1")
        #expect(conv1Rows.map(\.id) == ["B", "C", "P2", "P3"])

        // nextReadyConversation picks the conversation of the lowest ready seq.
        // "B" (seq 2, future) is not ready; "C" (seq 3, past) is.
        let ready = try await store.nextReadyConversation(now: now)
        #expect(ready == "conv-1")
        let readyEarly = try await store.nextReadyConversation(now: Date(timeIntervalSince1970: 50))
        #expect(readyEarly == nil)

        let conversations = try await store.conversationsWithPendingChanges()
        #expect(conversations == ["conv-1", "conv-2"])

        // Reschedule pushes rows out and skips deleted ids without re-inserting.
        try await store.reschedule(ids: ["C", "A"], attemptCount: 2, nextAttemptAt: future, lastError: "boom", updatedAt: now)
        let resurrectedA = try await store.rowExists(id: "A")
        #expect(resurrectedA == false)
        let afterReschedule = try await store.pendingChanges(conversationId: "conv-1")
        let rescheduledC = afterReschedule.first { $0.id == "C" }
        #expect(rescheduledC?.attemptCount == 2)
        #expect(rescheduledC?.nextAttemptAt == future)
        #expect(rescheduledC?.lastError == "boom")

        // earliestNextAttempt spans all rows (P2/P3/D still at past).
        let earliest = try await store.earliestNextAttempt()
        #expect(earliest == past)

        // resetBackoff makes the conversation immediately ready again.
        try await store.resetBackoff(conversationId: "conv-1", now: now)
        let afterReset = try await store.pendingChanges(conversationId: "conv-1")
        #expect(afterReset.allSatisfy { $0.attemptCount == 0 && $0.nextAttemptAt == now })
        let untouched = try await store.pendingChanges(conversationId: "conv-2")
        #expect(untouched.first?.nextAttemptAt == past)

        // Targeted and per-conversation deletes.
        try await store.delete(ids: ["P2"])
        let p2Gone = try await store.rowExists(id: "P2")
        #expect(p2Gone == false)
        try await store.deleteAll(conversationId: "conv-1")
        let conv1Empty = try await store.pendingChanges(conversationId: "conv-1")
        #expect(conv1Empty.isEmpty)
        let conv2Still = try await store.pendingChanges(conversationId: "conv-2")
        #expect(conv2Still.count == 1)

        try await store.deleteAll()
        let allGone = try await store.conversationsWithPendingChanges()
        #expect(allGone.isEmpty)
        let noneReady = try await store.nextReadyConversation(now: future)
        #expect(noneReady == nil)
        let noAttempts = try await store.earliestNextAttempt()
        #expect(noAttempts == nil)
    }
}
