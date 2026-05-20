@testable import ConvosCore
import Foundation
import GRDB
import Testing

@Suite("AgentTemplateContactsRepository Tests", .serialized)
struct AgentTemplateContactsRepositoryTests {
    @Test("fetchAll returns agent-template contacts sorted case-insensitively by name")
    func testFetchAllSortsAlphabetically() async throws {
        let dbManager = MockDatabaseManager.makeTestDatabase()
        let writer = AgentTemplateContactsWriter(databaseWriter: dbManager.dbWriter)
        let repository = AgentTemplateContactsRepository(databaseReader: dbManager.dbReader)

        try await writer.upsert(
            templateId: "t-charlie",
            addedViaConversationId: nil,
            profile: AgentTemplateContactSnapshot(displayName: "Charlie")
        )
        try await writer.upsert(
            templateId: "t-alice",
            addedViaConversationId: nil,
            profile: AgentTemplateContactSnapshot(displayName: "alice")
        )
        try await writer.upsert(
            templateId: "t-bob",
            addedViaConversationId: nil,
            profile: AgentTemplateContactSnapshot(displayName: "Bob")
        )

        let all = try repository.fetchAll()
        #expect(all.map(\.resolvedDisplayName) == ["alice", "Bob", "Charlie"])
    }

    @Test("fetchContact returns the matching contact and nil for an unknown templateId")
    func testFetchContact() async throws {
        let dbManager = MockDatabaseManager.makeTestDatabase()
        let writer = AgentTemplateContactsWriter(databaseWriter: dbManager.dbWriter)
        let repository = AgentTemplateContactsRepository(databaseReader: dbManager.dbReader)

        try await writer.upsert(
            templateId: "t-1",
            addedViaConversationId: nil,
            profile: AgentTemplateContactSnapshot(displayName: "Tifoso", emoji: "🚴")
        )

        let found = try repository.fetchContact(templateId: "t-1")
        #expect(found?.templateId == "t-1")
        #expect(found?.displayName == "Tifoso")
        #expect(found?.emoji == "🚴")

        let missing = try repository.fetchContact(templateId: "t-unknown")
        #expect(missing == nil)
    }

    @Test("isContact reflects whether a templateId has a stored row")
    func testIsContact() async throws {
        let dbManager = MockDatabaseManager.makeTestDatabase()
        let writer = AgentTemplateContactsWriter(databaseWriter: dbManager.dbWriter)
        let repository = AgentTemplateContactsRepository(databaseReader: dbManager.dbReader)

        try await writer.upsert(
            templateId: "t-1",
            addedViaConversationId: nil,
            profile: AgentTemplateContactSnapshot(displayName: "Tifoso")
        )

        #expect(try repository.isContact(templateId: "t-1") == true)
        #expect(try repository.isContact(templateId: "t-unknown") == false)
    }

    @Test("A contact with no name resolves to a truncated templateId")
    func testResolvedDisplayNameFallsBackToShortTemplateId() async throws {
        let dbManager = MockDatabaseManager.makeTestDatabase()
        let writer = AgentTemplateContactsWriter(databaseWriter: dbManager.dbWriter)
        let repository = AgentTemplateContactsRepository(databaseReader: dbManager.dbReader)

        let templateId = "200e27dc-badc-429f-a431-b01b0281ec95"
        try await writer.upsert(
            templateId: templateId,
            addedViaConversationId: nil,
            profile: AgentTemplateContactSnapshot(displayName: nil)
        )

        let found = try repository.fetchContact(templateId: templateId)
        #expect(found?.resolvedDisplayName == "200e27dc")
    }
}
