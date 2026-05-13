@testable import ConvosCore
import Foundation
import GRDB
import Testing

@Suite("SessionManager delete-all-data", .serialized)
struct SessionManagerDeleteAllDataTests {
    @Test("deleteAllInboxes clears contacts and other account-scoped rows")
    func clearsAccountScopedRows() async throws {
        let databaseManager = MockDatabaseManager.makeTestDatabase()
        let session = SessionManager(
            databaseWriter: databaseManager.dbWriter,
            databaseReader: databaseManager.dbReader,
            environment: .tests,
            identityStore: MockKeychainIdentityStore(),
            platformProviders: .mock
        )

        try databaseManager.dbWriter.write { db in
            try DBContact(
                inboxId: "contact-1",
                addedAt: Date(),
                addedViaConversationId: nil,
                displayName: "Alice"
            ).save(db)

            try DBMyProfile(
                inboxId: "self",
                name: "Me"
            ).save(db)
        }

        for try await _ in session.deleteAllInboxesWithProgress() {}

        try databaseManager.dbReader.read { db in
            #expect(try DBContact.fetchCount(db) == 0)
            #expect(try DBMyProfile.fetchCount(db) == 0)
            #expect(try DBConversation.fetchCount(db) == 0)
            #expect(try DBInbox.fetchCount(db) == 0)
        }
    }
}
