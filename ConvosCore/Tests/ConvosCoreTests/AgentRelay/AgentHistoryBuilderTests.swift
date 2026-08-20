@testable import ConvosCore
import Foundation
import Testing

@Suite("AgentRelay history")
struct AgentRelayHistoryBuilderTests {
    @Test("history keeps only the last ten completed turns")
    func historyCapsCompletedTurnCount() throws {
        let database = try AgentChatDatabase.inMemoryForTests()
        let writer = AgentChatWriter(database: database)
        let repository = AgentChatRepository(database: database)
        let start = Date(timeIntervalSince1970: 1_000)
        for index in 0 ..< 12 {
            let requestId = "request_\(index)"
            try writer.insertPending(makeAgentTurn(requestId: requestId, prompt: "Prompt \(index)", createdAt: start.addingTimeInterval(Double(index))))
            try writer.markCompleted(
                requestId: requestId,
                result: makeAgentRelayResult(message: "Result \(index)", completedAt: start.addingTimeInterval(Double(index) + 0.5)),
                provider: .town
            )
        }

        let history = try AgentHistoryBuilder(repository: repository).history(excluding: nil)

        #expect(history.count == 20)
        #expect(history.first?.text == "Prompt 2")
        #expect(history.last?.text == "Result 11")
    }

    @Test("history drops oldest entries until its character cap is met")
    func historyCapsCharactersOldestFirst() throws {
        let database = try AgentChatDatabase.inMemoryForTests()
        let writer = AgentChatWriter(database: database)
        let repository = AgentChatRepository(database: database)
        let start = Date(timeIntervalSince1970: 2_000)
        for index in 0 ..< 3 {
            let text = String(repeating: String(index), count: 15_000)
            let requestId = "request_large_\(index)"
            try writer.insertPending(makeAgentTurn(requestId: requestId, prompt: text, createdAt: start.addingTimeInterval(Double(index))))
            try writer.markCompleted(
                requestId: requestId,
                result: makeAgentRelayResult(message: text, completedAt: start.addingTimeInterval(Double(index) + 0.5)),
                provider: .town
            )
        }

        let history = try AgentHistoryBuilder(repository: repository).history(excluding: nil)
        let totalCharacters = history.reduce(into: 0) { count, entry in count += entry.text.count }

        #expect(totalCharacters <= 40_000)
        #expect(history.count == 2)
        #expect(history.allSatisfy { $0.text.first == "2" })
    }

    @Test("history excludes pending, failed, and the current request")
    func historyExcludesNonCompletedAndCurrentTurns() throws {
        let database = try AgentChatDatabase.inMemoryForTests()
        let writer = AgentChatWriter(database: database)
        let repository = AgentChatRepository(database: database)
        try writer.insertPending(makeAgentTurn(requestId: "request_keep", prompt: "Keep"))
        try writer.markCompleted(requestId: "request_keep", result: makeAgentRelayResult(message: "Kept"), provider: .town)
        try writer.insertPending(makeAgentTurn(requestId: "request_current", prompt: "Current"))
        try writer.markCompleted(requestId: "request_current", result: makeAgentRelayResult(message: "Current result"), provider: .town)
        try writer.insertPending(makeAgentTurn(requestId: "request_pending", prompt: "Pending"))
        try writer.insertPending(makeAgentTurn(requestId: "request_failed", prompt: "Failed"))
        try writer.markFailed(requestId: "request_failed", errorCode: "expected")

        let history = try AgentHistoryBuilder(repository: repository).history(excluding: "request_current")

        #expect(history.map(\.text) == ["Keep", "Kept"])
    }
}
