import Foundation
import GRDB

/// Persistence for the appData coordinator's durable outbox. Thin: round-trips
/// and the queue queries the drain loop needs. No merge logic or scheduling
/// here; `AppDataCoordinator` owns those. Unlike the profile publish queue
/// there is no claim state - all publishes serialize inside the coordinator
/// actor and the reconcile pass is idempotent, so rows are only ever inserted,
/// rescheduled, or deleted.
protocol AppDataPendingChangeStoreProtocol: Sendable {
    /// Atomically assigns the next `seq`, inserts the row the closure builds
    /// with it, and deletes older rows with the same
    /// (conversationId, domain, scopeKey) - all in one write so concurrent
    /// enqueues can't collide on `seq` and a same-domain re-enqueue can't race
    /// a publish. Returns the inserted row and the ids of the rows it
    /// superseded so the coordinator can transfer their waiters.
    func enqueueNext(
        _ makeChange: @Sendable @escaping (Int64) -> DBAppDataPendingChange
    ) async throws -> (inserted: DBAppDataPendingChange, supersededIds: [String])
    /// All pending rows for a conversation in `seq` order (enqueue order).
    func pendingChanges(conversationId: String) async throws -> [DBAppDataPendingChange]
    /// The conversation owning the lowest-`seq` row whose `nextAttemptAt` has
    /// passed, or nil when nothing is ready.
    func nextReadyConversation(now: Date) async throws -> String?
    func conversationsWithPendingChanges() async throws -> [String]
    /// Pushes the named rows to a later attempt. Rows deleted mid-flight
    /// (superseded) are skipped, never re-inserted.
    func reschedule(ids: [String], attemptCount: Int64, nextAttemptAt: Date, lastError: String?, updatedAt: Date) async throws
    /// Makes every row for the conversation immediately ready and clears its
    /// attempt count, so an observed network commit retries without backoff.
    func resetBackoff(conversationId: String, now: Date) async throws
    func delete(ids: [String]) async throws
    func deleteAll(conversationId: String) async throws
    /// The earliest `nextAttemptAt` across all rows, for arming the retry timer.
    func earliestNextAttempt() async throws -> Date?
    func rowExists(id: String) async throws -> Bool
    func deleteAll() async throws
}

final class GRDBAppDataPendingChangeStore: AppDataPendingChangeStoreProtocol {
    private let databaseWriter: any DatabaseWriter
    private let databaseReader: any DatabaseReader

    init(databaseWriter: any DatabaseWriter, databaseReader: any DatabaseReader) {
        self.databaseWriter = databaseWriter
        self.databaseReader = databaseReader
    }

    func enqueueNext(
        _ makeChange: @Sendable @escaping (Int64) -> DBAppDataPendingChange
    ) async throws -> (inserted: DBAppDataPendingChange, supersededIds: [String]) {
        try await databaseWriter.write { db in
            let seq = try Int64.fetchOne(db, sql: "SELECT COALESCE(MAX(seq), 0) + 1 FROM appDataPendingChange") ?? 1
            let change = makeChange(seq)
            var superseded = DBAppDataPendingChange
                .filter(DBAppDataPendingChange.Columns.conversationId == change.conversationId)
                .filter(DBAppDataPendingChange.Columns.domain == change.domain)
                .filter(DBAppDataPendingChange.Columns.seq < seq)
            if let scopeKey = change.scopeKey {
                superseded = superseded.filter(DBAppDataPendingChange.Columns.scopeKey == scopeKey)
            } else {
                superseded = superseded.filter(DBAppDataPendingChange.Columns.scopeKey == nil)
            }
            let supersededIds = try superseded.select(DBAppDataPendingChange.Columns.id, as: String.self).fetchAll(db)
            _ = try superseded.deleteAll(db)
            try change.save(db)
            return (change, supersededIds)
        }
    }

    func pendingChanges(conversationId: String) async throws -> [DBAppDataPendingChange] {
        try await databaseReader.read { db in
            try DBAppDataPendingChange
                .filter(DBAppDataPendingChange.Columns.conversationId == conversationId)
                .order(DBAppDataPendingChange.Columns.seq)
                .fetchAll(db)
        }
    }

    func nextReadyConversation(now: Date) async throws -> String? {
        try await databaseReader.read { db in
            try DBAppDataPendingChange
                .filter(DBAppDataPendingChange.Columns.nextAttemptAt <= now)
                .order(DBAppDataPendingChange.Columns.seq)
                .fetchOne(db)?
                .conversationId
        }
    }

    func conversationsWithPendingChanges() async throws -> [String] {
        try await databaseReader.read { db in
            try String.fetchAll(
                db,
                sql: "SELECT conversationId FROM appDataPendingChange GROUP BY conversationId ORDER BY MIN(seq)"
            )
        }
    }

    func reschedule(ids: [String], attemptCount: Int64, nextAttemptAt: Date, lastError: String?, updatedAt: Date) async throws {
        try await databaseWriter.write { db in
            _ = try DBAppDataPendingChange
                .filter(ids.contains(DBAppDataPendingChange.Columns.id))
                .updateAll(
                    db,
                    DBAppDataPendingChange.Columns.attemptCount.set(to: attemptCount),
                    DBAppDataPendingChange.Columns.nextAttemptAt.set(to: nextAttemptAt),
                    DBAppDataPendingChange.Columns.lastError.set(to: lastError),
                    DBAppDataPendingChange.Columns.updatedAt.set(to: updatedAt)
                )
        }
    }

    func resetBackoff(conversationId: String, now: Date) async throws {
        try await databaseWriter.write { db in
            _ = try DBAppDataPendingChange
                .filter(DBAppDataPendingChange.Columns.conversationId == conversationId)
                .updateAll(
                    db,
                    DBAppDataPendingChange.Columns.attemptCount.set(to: 0),
                    DBAppDataPendingChange.Columns.nextAttemptAt.set(to: now),
                    DBAppDataPendingChange.Columns.updatedAt.set(to: now)
                )
        }
    }

    func delete(ids: [String]) async throws {
        try await databaseWriter.write { db in
            _ = try DBAppDataPendingChange
                .filter(ids.contains(DBAppDataPendingChange.Columns.id))
                .deleteAll(db)
        }
    }

    func deleteAll(conversationId: String) async throws {
        try await databaseWriter.write { db in
            _ = try DBAppDataPendingChange
                .filter(DBAppDataPendingChange.Columns.conversationId == conversationId)
                .deleteAll(db)
        }
    }

    func earliestNextAttempt() async throws -> Date? {
        try await databaseReader.read { db in
            try Date.fetchOne(db, sql: "SELECT MIN(nextAttemptAt) FROM appDataPendingChange")
        }
    }

    func rowExists(id: String) async throws -> Bool {
        try await databaseReader.read { db in
            try DBAppDataPendingChange.exists(db, key: id)
        }
    }

    func deleteAll() async throws {
        try await databaseWriter.write { db in
            _ = try DBAppDataPendingChange.deleteAll(db)
        }
    }
}

actor InMemoryAppDataPendingChangeStore: AppDataPendingChangeStoreProtocol {
    private var changesById: [String: DBAppDataPendingChange] = [:]

    func enqueueNext(
        _ makeChange: @Sendable @escaping (Int64) -> DBAppDataPendingChange
    ) -> (inserted: DBAppDataPendingChange, supersededIds: [String]) {
        let seq = (changesById.values.map(\.seq).max() ?? 0) + 1
        let change = makeChange(seq)
        var supersededIds: [String] = []
        for entry in changesById where entry.value.conversationId == change.conversationId
            && entry.value.domain == change.domain
            && entry.value.scopeKey == change.scopeKey
            && entry.value.seq < seq {
            supersededIds.append(entry.key)
            changesById[entry.key] = nil
        }
        changesById[change.id] = change
        return (change, supersededIds)
    }

    func pendingChanges(conversationId: String) -> [DBAppDataPendingChange] {
        changesById.values
            .filter { $0.conversationId == conversationId }
            .sorted { $0.seq < $1.seq }
    }

    func nextReadyConversation(now: Date) -> String? {
        changesById.values
            .filter { $0.nextAttemptAt <= now }
            .min { $0.seq < $1.seq }?
            .conversationId
    }

    func conversationsWithPendingChanges() -> [String] {
        var earliestSeqByConversation: [String: Int64] = [:]
        for change in changesById.values {
            let existing = earliestSeqByConversation[change.conversationId]
            earliestSeqByConversation[change.conversationId] = min(existing ?? change.seq, change.seq)
        }
        return earliestSeqByConversation
            .sorted { $0.value < $1.value }
            .map(\.key)
    }

    func reschedule(ids: [String], attemptCount: Int64, nextAttemptAt: Date, lastError: String?, updatedAt: Date) {
        for id in ids {
            guard var change = changesById[id] else { continue }
            change.attemptCount = attemptCount
            change.nextAttemptAt = nextAttemptAt
            change.lastError = lastError
            change.updatedAt = updatedAt
            changesById[id] = change
        }
    }

    func resetBackoff(conversationId: String, now: Date) {
        for (id, change) in changesById where change.conversationId == conversationId {
            var updated = change
            updated.attemptCount = 0
            updated.nextAttemptAt = now
            updated.updatedAt = now
            changesById[id] = updated
        }
    }

    func delete(ids: [String]) {
        for id in ids {
            changesById[id] = nil
        }
    }

    func deleteAll(conversationId: String) {
        for entry in changesById where entry.value.conversationId == conversationId {
            changesById[entry.key] = nil
        }
    }

    func earliestNextAttempt() -> Date? {
        changesById.values.map(\.nextAttemptAt).min()
    }

    func rowExists(id: String) -> Bool {
        changesById[id] != nil
    }

    func deleteAll() {
        changesById.removeAll()
    }
}
