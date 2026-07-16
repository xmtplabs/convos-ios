import Foundation
import GRDB

/// Persistence for the durable profile publish queue: the current user's
/// plaintext source avatar (`DBProfileAvatarSource`) and the per-conversation
/// publish jobs (`DBProfilePublishJob`). Thin: round-trips and the queue queries
/// (`nextReadyJob`, `nextSeq`, `earliestNextAttempt`, `supersedeOlderThan`) the
/// drain loop needs. No state transitions or scheduling here; `ProfilePublisher`
/// owns those.
///
/// Not wired into the app yet; introduced ahead of `ProfilePublisher`.
protocol ProfilePublishStoreProtocol: Sendable {
    // Source image
    func setSource(_ source: DBProfileAvatarSource) async throws
    /// Atomically records new source bytes at `previous version + 1` and returns
    /// the new version, so concurrent avatar edits can't read the same version
    /// and both write it (which would defeat the stale-source supersede check).
    func bumpAvatarSource(inboxId: String, plaintext: Data, updatedAt: Date) async throws -> Int64
    func source(inboxId: String) async throws -> DBProfileAvatarSource?
    func clearSource(inboxId: String) async throws

    // Job queue
    func enqueue(_ job: DBProfilePublishJob) async throws
    /// Atomically assigns the next `seq`, inserts the job the closure builds with
    /// it, and supersedes that conversation's older non-done jobs - all in one
    /// write so concurrent enqueues can't collide on `seq`. Returns the inserted
    /// job so a caller can process it directly.
    @discardableResult
    func enqueueNext(_ makeJob: @Sendable @escaping (Int64) -> DBProfilePublishJob) async throws -> DBProfilePublishJob
    /// Updates an existing job. Throws `ProfilePublishStoreError.jobNotFound`
    /// when the row is gone (superseded and deleted mid-flight) - it must never
    /// re-insert, or a superseded job would be resurrected by its own state
    /// writes and retried after a newer publish intent.
    func update(_ job: DBProfilePublishJob) async throws
    /// Atomically transitions a `pending` job to `uploading` and returns it, or
    /// nil when the job is no longer pending (claimed by another drain, or
    /// superseded and deleted). The atomic check-and-set is what lets the
    /// inline per-conversation publish path and the background drain coexist
    /// without double-processing a job.
    func claimJob(id: String, updatedAt: Date) async throws -> DBProfilePublishJob?
    func job(id: String) async throws -> DBProfilePublishJob?
    /// The next `pending` job whose `nextAttemptAt` has passed, lowest `seq`
    /// first. Excludes `uploading` (in-flight) and `done` jobs so a claimed job
    /// is never handed out twice. Fetch only; the publisher transitions state
    /// via `update`.
    func nextReadyJob(now: Date) async throws -> DBProfilePublishJob?
    /// Returns any `uploading` jobs to `pending`, e.g. after a drain was
    /// interrupted mid-flight, so they become eligible for retry.
    /// Returns `uploading` jobs to `pending` so work stranded mid-flight (e.g.
    /// by a crash) becomes ready again. `excluding` names jobs currently being
    /// processed in this process - live, not stranded - which must keep their
    /// claim or they would be processed twice.
    func reclaimStalledJobs(excluding: Set<String>) async throws
    func activeJobs() async throws -> [DBProfilePublishJob]
    func jobs(conversationId: String) async throws -> [DBProfilePublishJob]
    func nextSeq() async throws -> Int64
    func earliestNextAttempt() async throws -> Date?
    func deleteJob(id: String) async throws
    func deleteJobs(conversationId: String) async throws
    /// Drops non-done jobs for a conversation older than `seq`, so a newer
    /// publish intent supersedes stale ones.
    func supersedeOlderThan(conversationId: String, seq: Int64) async throws
    func deleteAll() async throws
}

final class GRDBProfilePublishStore: ProfilePublishStoreProtocol {
    private let databaseWriter: any DatabaseWriter
    private let databaseReader: any DatabaseReader

    init(databaseWriter: any DatabaseWriter, databaseReader: any DatabaseReader) {
        self.databaseWriter = databaseWriter
        self.databaseReader = databaseReader
    }

    func setSource(_ source: DBProfileAvatarSource) async throws {
        try await databaseWriter.write { db in
            try source.save(db)
        }
    }

    func bumpAvatarSource(inboxId: String, plaintext: Data, updatedAt: Date) async throws -> Int64 {
        try await databaseWriter.write { db in
            let existing = try DBProfileAvatarSource.fetchOne(db, inboxId: inboxId)
            let version = (existing?.version ?? 0) + 1
            try DBProfileAvatarSource(inboxId: inboxId, plaintext: plaintext, version: version, updatedAt: updatedAt).save(db)
            return version
        }
    }

    func source(inboxId: String) async throws -> DBProfileAvatarSource? {
        try await databaseReader.read { db in
            try DBProfileAvatarSource.fetchOne(db, inboxId: inboxId)
        }
    }

    func clearSource(inboxId: String) async throws {
        try await databaseWriter.write { db in
            _ = try DBProfileAvatarSource.deleteOne(db, key: inboxId)
        }
    }

    func enqueue(_ job: DBProfilePublishJob) async throws {
        try await databaseWriter.write { db in
            try job.save(db)
        }
    }

    @discardableResult
    func enqueueNext(_ makeJob: @Sendable @escaping (Int64) -> DBProfilePublishJob) async throws -> DBProfilePublishJob {
        try await databaseWriter.write { db in
            let seq = try Int64.fetchOne(db, sql: "SELECT COALESCE(MAX(seq), 0) + 1 FROM profilePublishJob") ?? 1
            let job = makeJob(seq)
            try job.save(db)
            _ = try DBProfilePublishJob
                .filter(DBProfilePublishJob.Columns.conversationId == job.conversationId)
                .filter(DBProfilePublishJob.Columns.seq < seq)
                .deleteAll(db)
            return job
        }
    }

    func update(_ job: DBProfilePublishJob) async throws {
        try await databaseWriter.write { db in
            guard try DBProfilePublishJob.exists(db, key: job.id) else {
                throw ProfilePublishStoreError.jobNotFound
            }
            try job.save(db)
        }
    }

    func claimJob(id: String, updatedAt: Date) async throws -> DBProfilePublishJob? {
        try await databaseWriter.write { db in
            guard var job = try DBProfilePublishJob.fetchOne(db, id: id),
                  job.state == .pending else {
                return nil
            }
            job.state = .uploading
            job.updatedAt = updatedAt
            try job.save(db)
            return job
        }
    }

    func job(id: String) async throws -> DBProfilePublishJob? {
        try await databaseReader.read { db in
            try DBProfilePublishJob.fetchOne(db, id: id)
        }
    }

    func nextReadyJob(now: Date) async throws -> DBProfilePublishJob? {
        try await databaseReader.read { db in
            try DBProfilePublishJob
                .filter(DBProfilePublishJob.Columns.state == ProfilePublishJobState.pending.rawValue)
                .filter(DBProfilePublishJob.Columns.nextAttemptAt <= now)
                .order(DBProfilePublishJob.Columns.seq)
                .fetchOne(db)
        }
    }

    func reclaimStalledJobs(excluding: Set<String>) async throws {
        try await databaseWriter.write { db in
            _ = try DBProfilePublishJob
                .filter(DBProfilePublishJob.Columns.state == ProfilePublishJobState.uploading.rawValue)
                .filter(!excluding.contains(DBProfilePublishJob.Columns.id))
                .updateAll(db, DBProfilePublishJob.Columns.state.set(to: ProfilePublishJobState.pending.rawValue))
        }
    }

    func activeJobs() async throws -> [DBProfilePublishJob] {
        try await databaseReader.read { db in
            try DBProfilePublishJob
                .filter(DBProfilePublishJob.Columns.state != ProfilePublishJobState.done.rawValue)
                .order(DBProfilePublishJob.Columns.seq)
                .fetchAll(db)
        }
    }

    func jobs(conversationId: String) async throws -> [DBProfilePublishJob] {
        try await databaseReader.read { db in
            try DBProfilePublishJob
                .filter(DBProfilePublishJob.Columns.conversationId == conversationId)
                .order(DBProfilePublishJob.Columns.seq)
                .fetchAll(db)
        }
    }

    func nextSeq() async throws -> Int64 {
        try await databaseReader.read { db in
            try Int64.fetchOne(db, sql: "SELECT COALESCE(MAX(seq), 0) + 1 FROM profilePublishJob") ?? 1
        }
    }

    func earliestNextAttempt() async throws -> Date? {
        try await databaseReader.read { db in
            try Date.fetchOne(
                db,
                sql: "SELECT MIN(nextAttemptAt) FROM profilePublishJob WHERE state <> ?",
                arguments: [ProfilePublishJobState.done.rawValue]
            )
        }
    }

    func deleteJob(id: String) async throws {
        try await databaseWriter.write { db in
            _ = try DBProfilePublishJob.deleteOne(db, key: id)
        }
    }

    func deleteJobs(conversationId: String) async throws {
        try await databaseWriter.write { db in
            _ = try DBProfilePublishJob
                .filter(DBProfilePublishJob.Columns.conversationId == conversationId)
                .deleteAll(db)
        }
    }

    func supersedeOlderThan(conversationId: String, seq: Int64) async throws {
        try await databaseWriter.write { db in
            _ = try DBProfilePublishJob
                .filter(DBProfilePublishJob.Columns.conversationId == conversationId)
                .filter(DBProfilePublishJob.Columns.seq < seq)
                .deleteAll(db)
        }
    }

    func deleteAll() async throws {
        try await databaseWriter.write { db in
            _ = try DBProfilePublishJob.deleteAll(db)
            _ = try DBProfileAvatarSource.deleteAll(db)
        }
    }
}

actor InMemoryProfilePublishStore: ProfilePublishStoreProtocol {
    private var sourcesByInbox: [String: DBProfileAvatarSource] = [:]
    private var jobsById: [String: DBProfilePublishJob] = [:]

    func setSource(_ source: DBProfileAvatarSource) {
        sourcesByInbox[source.inboxId] = source
    }

    func bumpAvatarSource(inboxId: String, plaintext: Data, updatedAt: Date) -> Int64 {
        let version = (sourcesByInbox[inboxId]?.version ?? 0) + 1
        sourcesByInbox[inboxId] = DBProfileAvatarSource(inboxId: inboxId, plaintext: plaintext, version: version, updatedAt: updatedAt)
        return version
    }

    func source(inboxId: String) -> DBProfileAvatarSource? {
        sourcesByInbox[inboxId]
    }

    func clearSource(inboxId: String) {
        sourcesByInbox[inboxId] = nil
    }

    func enqueue(_ job: DBProfilePublishJob) {
        jobsById[job.id] = job
    }

    @discardableResult
    func enqueueNext(_ makeJob: @Sendable @escaping (Int64) -> DBProfilePublishJob) -> DBProfilePublishJob {
        let seq = (jobsById.values.map(\.seq).max() ?? 0) + 1
        let job = makeJob(seq)
        jobsById[job.id] = job
        for entry in jobsById where entry.value.conversationId == job.conversationId && entry.value.seq < seq {
            jobsById[entry.key] = nil
        }
        return job
    }

    func update(_ job: DBProfilePublishJob) throws {
        guard jobsById[job.id] != nil else {
            throw ProfilePublishStoreError.jobNotFound
        }
        jobsById[job.id] = job
    }

    func claimJob(id: String, updatedAt: Date) -> DBProfilePublishJob? {
        guard var job = jobsById[id], job.state == .pending else { return nil }
        job.state = .uploading
        job.updatedAt = updatedAt
        jobsById[id] = job
        return job
    }

    func job(id: String) -> DBProfilePublishJob? {
        jobsById[id]
    }

    func nextReadyJob(now: Date) -> DBProfilePublishJob? {
        jobsById.values
            .filter { $0.state == .pending && $0.nextAttemptAt <= now }
            .min { $0.seq < $1.seq }
    }

    func reclaimStalledJobs(excluding: Set<String>) {
        for (id, job) in jobsById where job.state == .uploading && !excluding.contains(id) {
            var updated = job
            updated.state = .pending
            jobsById[id] = updated
        }
    }

    func activeJobs() -> [DBProfilePublishJob] {
        jobsById.values
            .filter { $0.state != .done }
            .sorted { $0.seq < $1.seq }
    }

    func jobs(conversationId: String) -> [DBProfilePublishJob] {
        jobsById.values
            .filter { $0.conversationId == conversationId }
            .sorted { $0.seq < $1.seq }
    }

    func nextSeq() -> Int64 {
        (jobsById.values.map(\.seq).max() ?? 0) + 1
    }

    func earliestNextAttempt() -> Date? {
        jobsById.values
            .filter { $0.state != .done }
            .map(\.nextAttemptAt)
            .min()
    }

    func deleteJob(id: String) {
        jobsById[id] = nil
    }

    func deleteJobs(conversationId: String) {
        for entry in jobsById where entry.value.conversationId == conversationId {
            jobsById[entry.key] = nil
        }
    }

    func supersedeOlderThan(conversationId: String, seq: Int64) {
        for entry in jobsById where entry.value.conversationId == conversationId && entry.value.seq < seq {
            jobsById[entry.key] = nil
        }
    }

    func deleteAll() {
        jobsById.removeAll()
        sourcesByInbox.removeAll()
    }
}

enum ProfilePublishStoreError: Error {
    case jobNotFound
}
