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
    func source(inboxId: String) async throws -> DBProfileAvatarSource?
    func clearSource(inboxId: String) async throws

    // Job queue
    func enqueue(_ job: DBProfilePublishJob) async throws
    func update(_ job: DBProfilePublishJob) async throws
    func job(id: String) async throws -> DBProfilePublishJob?
    /// The next non-done job whose `nextAttemptAt` has passed, lowest `seq`
    /// first. Fetch only; the publisher transitions state via `update`.
    func nextReadyJob(now: Date) async throws -> DBProfilePublishJob?
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

    func update(_ job: DBProfilePublishJob) async throws {
        try await databaseWriter.write { db in
            try job.save(db)
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
                .filter(DBProfilePublishJob.Columns.state != ProfilePublishJobState.done.rawValue)
                .filter(DBProfilePublishJob.Columns.nextAttemptAt <= now)
                .order(DBProfilePublishJob.Columns.seq)
                .fetchOne(db)
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

    func source(inboxId: String) -> DBProfileAvatarSource? {
        sourcesByInbox[inboxId]
    }

    func clearSource(inboxId: String) {
        sourcesByInbox[inboxId] = nil
    }

    func enqueue(_ job: DBProfilePublishJob) {
        jobsById[job.id] = job
    }

    func update(_ job: DBProfilePublishJob) {
        jobsById[job.id] = job
    }

    func job(id: String) -> DBProfilePublishJob? {
        jobsById[id]
    }

    func nextReadyJob(now: Date) -> DBProfilePublishJob? {
        jobsById.values
            .filter { $0.state != .done && $0.nextAttemptAt <= now }
            .min { $0.seq < $1.seq }
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
