@testable import ConvosCore
import Foundation
import GRDB
import Testing

/// Contract tests for `ProfilePublishStoreProtocol`, run against both
/// implementations. Covers source round-trip, `nextSeq` monotonicity,
/// `nextReadyJob` ordering and readiness, `activeJobs`/`jobs` ordering,
/// `earliestNextAttempt`, and supersede/delete.
@Suite("Profile publish store")
struct ProfilePublishStoreTests {
    @Test("GRDB implementation satisfies the contract")
    func grdbContract() async throws {
        let queue = try ProfileStoreTestSupport.makeQueue(conversations: ["conv-1", "conv-2"])
        let store = GRDBProfilePublishStore(databaseWriter: queue, databaseReader: queue)
        try await runContract(store)
    }

    @Test("in-memory implementation satisfies the contract")
    func inMemoryContract() async throws {
        try await runContract(InMemoryProfilePublishStore())
    }

    private func job(_ id: String, _ seq: Int64, _ conversationId: String, _ at: Date) -> DBProfilePublishJob {
        DBProfilePublishJob(
            id: id,
            seq: seq,
            conversationId: conversationId,
            nextAttemptAt: at,
            createdAt: at,
            updatedAt: at
        )
    }

    private func runContract(_ store: any ProfilePublishStoreProtocol) async throws {
        let past1 = Date(timeIntervalSince1970: 100)
        let past2 = Date(timeIntervalSince1970: 200)
        let now = Date(timeIntervalSince1970: 1_000)
        let future = Date(timeIntervalSince1970: 5_000)

        // Source round-trip.
        let noSource = try await store.source(inboxId: "me")
        #expect(noSource == nil)
        try await store.setSource(DBProfileAvatarSource(inboxId: "me", plaintext: Data([1]), version: 1, updatedAt: past1))
        let v1 = try await store.source(inboxId: "me")
        #expect(v1?.version == 1)
        try await store.setSource(DBProfileAvatarSource(inboxId: "me", plaintext: Data([2]), version: 2, updatedAt: past2))
        let v2 = try await store.source(inboxId: "me")
        #expect(v2?.version == 2)

        // Enqueue jobs across conversations and readiness windows.
        let seqStart = try await store.nextSeq()
        #expect(seqStart == 1)
        try await store.enqueue(job("A", 1, "conv-1", past1))
        try await store.enqueue(job("B", 2, "conv-1", future))
        try await store.enqueue(job("C", 3, "conv-2", past2))

        let seqNext = try await store.nextSeq()
        #expect(seqNext == 4)
        let fetchedA = try await store.job(id: "A")
        #expect(fetchedA != nil)
        let fetchedMissing = try await store.job(id: "Z")
        #expect(fetchedMissing == nil)

        // Ready = non-done with nextAttemptAt <= now, lowest seq first.
        let ready = try await store.nextReadyJob(now: now)
        #expect(ready?.id == "A")
        let active = try await store.activeJobs()
        #expect(active.map(\.id) == ["A", "B", "C"])
        let conv1 = try await store.jobs(conversationId: "conv-1")
        #expect(conv1.map(\.id) == ["A", "B"])
        let earliest = try await store.earliestNextAttempt()
        #expect(earliest == past1)

        // Marking A done removes it from ready/active and shifts earliest.
        if var done = try await store.job(id: "A") {
            done.state = .done
            try await store.update(done)
        }
        let readyAfterDone = try await store.nextReadyJob(now: now)
        #expect(readyAfterDone?.id == "C")
        let activeAfterDone = try await store.activeJobs()
        #expect(activeAfterDone.map(\.id) == ["B", "C"])
        let earliestAfterDone = try await store.earliestNextAttempt()
        #expect(earliestAfterDone == past2)

        // Supersede drops conv-1 jobs older than seq 2 (deletes A).
        try await store.supersedeOlderThan(conversationId: "conv-1", seq: 2)
        let supersededA = try await store.job(id: "A")
        #expect(supersededA == nil)
        let activeAfterSupersede = try await store.activeJobs()
        #expect(activeAfterSupersede.map(\.id) == ["B", "C"])

        // Delete by conversation, then by id.
        try await store.deleteJobs(conversationId: "conv-2")
        let activeAfterConvDelete = try await store.activeJobs()
        #expect(activeAfterConvDelete.map(\.id) == ["B"])
        try await store.deleteJob(id: "B")
        let activeEmpty = try await store.activeJobs()
        #expect(activeEmpty.isEmpty)
        let readyNone = try await store.nextReadyJob(now: now)
        #expect(readyNone == nil)
        let earliestNone = try await store.earliestNextAttempt()
        #expect(earliestNone == nil)

        // clearSource and deleteAll.
        try await store.clearSource(inboxId: "me")
        let clearedSource = try await store.source(inboxId: "me")
        #expect(clearedSource == nil)
        try await store.setSource(DBProfileAvatarSource(inboxId: "me", plaintext: Data([3]), version: 3, updatedAt: past1))
        try await store.enqueue(job("D", 5, "conv-1", past1))
        try await store.deleteAll()
        let sourceAfterDeleteAll = try await store.source(inboxId: "me")
        #expect(sourceAfterDeleteAll == nil)
        let jobsAfterDeleteAll = try await store.activeJobs()
        #expect(jobsAfterDeleteAll.isEmpty)
    }
}
