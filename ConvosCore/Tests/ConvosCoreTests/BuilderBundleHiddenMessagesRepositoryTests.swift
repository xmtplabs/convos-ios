@testable import ConvosCore
import Foundation
import GRDB
import Testing

@Suite("BuilderBundleHiddenMessagesRepository Tests", .serialized)
struct BuilderBundleHiddenMessagesRepositoryTests {
    @Test("hiddenMessageIdsSync returns the flagged ids scoped to the conversation")
    func syncFetchScopedByConversation() async throws {
        let fixtures = try await makeTestFixtures()
        try await fixtures.dbWriter.write { db in
            try DBBuilderBundleHiddenMessage(conversationId: "c1", messageId: "m1").insert(db)
            try DBBuilderBundleHiddenMessage(conversationId: "c1", messageId: "m2").insert(db)
            try DBBuilderBundleHiddenMessage(conversationId: "c2", messageId: "m3").insert(db)
        }

        let repo = BuilderBundleHiddenMessagesRepository(databaseReader: fixtures.dbReader)
        #expect(repo.hiddenMessageIdsSync(in: "c1") == ["m1", "m2"])
        #expect(repo.hiddenMessageIdsSync(in: "c2") == ["m3"])
    }

    @Test("hiddenMessageIdsSync is empty for a conversation with no flagged ids")
    func syncFetchEmptyForUnknown() async throws {
        let fixtures = try await makeTestFixtures()
        let repo = BuilderBundleHiddenMessagesRepository(databaseReader: fixtures.dbReader)
        #expect(repo.hiddenMessageIdsSync(in: "missing").isEmpty)
    }

    @Test("duplicate (conversationId, messageId) rows collapse to one id")
    func duplicateInsertsIgnored() async throws {
        let fixtures = try await makeTestFixtures()
        // The manifest and its bundle messages can arrive in either order, so
        // the writer saves with `.ignore` -- a repeated id must not duplicate.
        try await fixtures.dbWriter.write { db in
            try DBBuilderBundleHiddenMessage(conversationId: "c1", messageId: "m1").save(db, onConflict: .ignore)
            try DBBuilderBundleHiddenMessage(conversationId: "c1", messageId: "m1").save(db, onConflict: .ignore)
        }

        let repo = BuilderBundleHiddenMessagesRepository(databaseReader: fixtures.dbReader)
        #expect(repo.hiddenMessageIdsSync(in: "c1") == ["m1"])
    }

    // MARK: - Test Helpers

    struct TestFixtures {
        let dbWriter: any DatabaseWriter
        let dbReader: any DatabaseReader
    }

    func makeTestFixtures() async throws -> TestFixtures {
        let dbManager = MockDatabaseManager.makeTestDatabase()
        return TestFixtures(dbWriter: dbManager.dbWriter, dbReader: dbManager.dbReader)
    }
}
