@testable import ConvosCore
import Foundation
import GRDB
import Testing

@Suite("AgentRelay database")
struct AgentRelayDatabaseTests {
    @Test("migration creates the turn table columns and status index")
    func migrationCreatesSchema() throws {
        let database = try AgentChatDatabase.inMemoryForTests()
        let schema = try database.pool.read { db in
            let columns = try db.columns(in: AgentTurn.databaseTableName).map(\.name)
            let indexes = try db.indexes(on: AgentTurn.databaseTableName).map(\.name)
            return (columns, indexes)
        }

        #expect(schema.0 == [
            "requestId", "provider", "status", "prompt", "resultMessage", "resultLinks",
            "errorCode", "createdAt", "expiresAt", "completedAt", "ackedAt",
        ])
        #expect(schema.1.contains("agent_turn_status_created"))
    }

    @Test("repository limits from the tail and returns newest last")
    func repositoryReturnsTailNewestLast() throws {
        let database = try AgentChatDatabase.inMemoryForTests()
        let writer = AgentChatWriter(database: database)
        let repository = AgentChatRepository(database: database)
        let start = Date(timeIntervalSince1970: 1_000)
        for index in 0 ..< 4 {
            try writer.insertPending(makeAgentTurn(requestId: "request_\(index)", createdAt: start.addingTimeInterval(Double(index))))
        }

        let turns = try repository.turns(limit: 2)
        #expect(turns.map(\.requestId) == ["request_2", "request_3"])
    }

    @Test("pending repository excludes terminal turns")
    func pendingRepositoryFiltersStatus() throws {
        let database = try AgentChatDatabase.inMemoryForTests()
        let writer = AgentChatWriter(database: database)
        let repository = AgentChatRepository(database: database)
        try writer.insertPending(makeAgentTurn(requestId: "request_pending"))
        try writer.insertPending(makeAgentTurn(requestId: "request_failed"))
        try writer.markFailed(requestId: "request_failed", errorCode: "expected")

        #expect(try repository.pendingTurns().map(\.requestId) == ["request_pending"])
    }

    @Test("turns stream yields its initial value")
    func turnsStreamYieldsInitialValue() async throws {
        let database = try AgentChatDatabase.inMemoryForTests()
        let repository = AgentChatRepository(database: database)
        var iterator = repository.turnsStream(limit: 10).makeAsyncIterator()

        let value = await iterator.next()
        #expect(value?.isEmpty == true)
    }

    @Test("mark completed inserts a missing turn")
    func completedUpsertInsertsMissingTurn() throws {
        let database = try AgentChatDatabase.inMemoryForTests()
        let writer = AgentChatWriter(database: database)
        let repository = AgentChatRepository(database: database)
        let completedAt = Date(timeIntervalSince1970: 2_000)

        try writer.markCompleted(
            requestId: "request_remote",
            result: makeAgentRelayResult(message: "Remote", completedAt: completedAt),
            provider: .tasklet
        )

        let turn = try repository.turn(requestId: "request_remote")
        #expect(turn?.provider == .tasklet)
        #expect(turn?.status == .completed)
        #expect(turn?.prompt == "(completed on another device)")
        #expect(turn?.resultMessage == "Remote")
        #expect(turn?.completedAt == completedAt)
    }

    @Test("mark completed updates a pending turn without changing provider or prompt")
    func completedUpsertUpdatesPendingTurn() throws {
        let database = try AgentChatDatabase.inMemoryForTests()
        let writer = AgentChatWriter(database: database)
        let repository = AgentChatRepository(database: database)
        let pending = makeAgentTurn(requestId: "request_local", prompt: "Keep me")
        try writer.insertPending(pending)

        try writer.markCompleted(
            requestId: pending.requestId,
            result: makeAgentRelayResult(message: "Finished"),
            provider: .tasklet
        )

        let turn = try repository.turn(requestId: pending.requestId)
        #expect(turn?.provider == .town)
        #expect(turn?.prompt == "Keep me")
        #expect(turn?.status == .completed)
        #expect(turn?.resultMessage == "Finished")
    }

    @Test("duplicate completion does not change completed or acknowledged state")
    func duplicateCompletionIsNoOp() throws {
        let database = try AgentChatDatabase.inMemoryForTests()
        let writer = AgentChatWriter(database: database)
        let repository = AgentChatRepository(database: database)
        let pending = makeAgentTurn(requestId: "request_duplicate")
        try writer.insertPending(pending)
        try writer.markCompleted(requestId: pending.requestId, result: makeAgentRelayResult(message: "First"), provider: .town)
        try writer.markAcked(requestId: pending.requestId)
        let first = try repository.turn(requestId: pending.requestId)

        try writer.markCompleted(requestId: pending.requestId, result: makeAgentRelayResult(message: "Second"), provider: .tasklet)
        let second = try repository.turn(requestId: pending.requestId)

        #expect(second == first)
    }
}
