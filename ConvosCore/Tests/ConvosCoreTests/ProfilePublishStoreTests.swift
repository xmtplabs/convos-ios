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

        // bumpAvatarSource assigns the next version atomically.
        let v3 = try await store.bumpAvatarSource(inboxId: "me", plaintext: Data([3]), updatedAt: past1)
        #expect(v3 == 3)
        let v4 = try await store.bumpAvatarSource(inboxId: "me", plaintext: Data([4]), updatedAt: past2)
        #expect(v4 == 4)
        let latestSource = try await store.source(inboxId: "me")
        #expect(latestSource?.version == 4)

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

        // enqueueNext assigns a monotonic seq atomically and supersedes older
        // jobs for the same conversation.
        try await store.enqueueNext { seq in
            DBProfilePublishJob(id: "E", seq: seq, conversationId: "conv-1", nextAttemptAt: past1, createdAt: past1, updatedAt: past1)
        }
        try await store.enqueueNext { seq in
            DBProfilePublishJob(id: "F", seq: seq, conversationId: "conv-1", nextAttemptAt: past1, createdAt: past1, updatedAt: past1)
        }
        let conv1Next = try await store.jobs(conversationId: "conv-1")
        // Older E superseded by newer F (same conversation).
        #expect(conv1Next.map(\.id) == ["F"])
        let fJob = try await store.job(id: "F")
        #expect((fJob?.seq ?? 0) > 0)

        // reclaimStalledJobs returns an in-flight (uploading) job to pending so
        // it is ready again; nextReadyJob excludes it while uploading.
        if var uploading = try await store.job(id: "F") {
            uploading.state = .uploading
            try await store.update(uploading)
        }
        let readyWhileUploading = try await store.nextReadyJob(now: now)
        #expect(readyWhileUploading == nil)
        try await store.reclaimStalledJobs()
        let readyAfterReclaim = try await store.nextReadyJob(now: now)
        #expect(readyAfterReclaim?.id == "F")

        // enqueueNext returns the job it inserted.
        let returned = try await store.enqueueNext { seq in
            DBProfilePublishJob(id: "G", seq: seq, conversationId: "conv-2", nextAttemptAt: past1, createdAt: past1, updatedAt: past1)
        }
        #expect(returned.id == "G")
        let storedG = try await store.job(id: "G")
        #expect(storedG?.seq == returned.seq)

        // claimJob atomically transitions pending -> uploading; a second claim
        // (no longer pending) and a claim of a missing job both return nil.
        let claimed = try await store.claimJob(id: "G", updatedAt: now)
        #expect(claimed?.state == .uploading)
        let claimedTwice = try await store.claimJob(id: "G", updatedAt: now)
        #expect(claimedTwice == nil)
        let claimedMissing = try await store.claimJob(id: "Z", updatedAt: now)
        #expect(claimedMissing == nil)

        // update refuses to resurrect a deleted job: a superseded in-flight
        // job's state writes must throw, not re-insert the row.
        try await store.deleteJob(id: "G")
        var ghost = returned
        ghost.state = .pending
        await #expect(throws: (any Error).self) {
            try await store.update(ghost)
        }
        let resurrected = try await store.job(id: "G")
        #expect(resurrected == nil)

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
