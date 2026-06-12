@testable import ConvosCore
import Foundation
import GRDB
import Testing

@Suite("DatabaseHandledJoinRequestStore")
struct DatabaseHandledJoinRequestStoreTests {
    private func makeDatabase() throws -> DatabaseQueue {
        let dbQueue = try DatabaseQueue()
        try SharedDatabaseMigrator.shared.migrate(database: dbQueue)
        return dbQueue
    }

    @Test("Marked message IDs are reported handled; unmarked are not")
    func marksAndReadsBack() async throws {
        let store = DatabaseHandledJoinRequestStore(databaseWriter: try makeDatabase())

        #expect(await store.isHandled(messageId: "msg-1") == false)

        await store.markHandled(messageId: "msg-1")

        #expect(await store.isHandled(messageId: "msg-1"))
        #expect(await store.isHandled(messageId: "msg-2") == false)
    }

    @Test("Marking the same message twice is idempotent")
    func markingIsIdempotent() async throws {
        let database = try makeDatabase()
        let store = DatabaseHandledJoinRequestStore(databaseWriter: database)

        await store.markHandled(messageId: "msg-1")
        await store.markHandled(messageId: "msg-1")

        let count = try await database.read { db in
            try DBHandledJoinRequest.fetchCount(db)
        }
        #expect(count == 1)
    }

    @Test("Rows past retention are pruned on write")
    func prunesExpiredRows() async throws {
        let database = try makeDatabase()
        let store = DatabaseHandledJoinRequestStore(databaseWriter: database)

        try await database.write { db in
            try DBHandledJoinRequest(
                messageId: "msg-old",
                handledAt: Date().addingTimeInterval(-31 * 24 * 60 * 60)
            ).save(db)
        }

        await store.markHandled(messageId: "msg-new")

        #expect(await store.isHandled(messageId: "msg-old") == false)
        #expect(await store.isHandled(messageId: "msg-new"))
    }
}
