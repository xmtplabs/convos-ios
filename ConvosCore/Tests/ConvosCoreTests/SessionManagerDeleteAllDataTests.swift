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

        try await databaseManager.dbWriter.write { db in
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

            try DBCreditBalance(
                id: DBCreditBalance.currentRowID,
                balance: 1_000,
                monthlyGrant: 1_000,
                monthlyGrantUsed: 0,
                nextRefreshAt: Date(),
                periodLabel: "month",
                updatedAt: Date()
            ).save(db)
        }

        for try await _ in session.deleteAllInboxesWithProgress() {}

        let contactCount = try await databaseManager.dbReader.read { db in
            try DBContact.fetchCount(db)
        }
        let myProfileCount = try await databaseManager.dbReader.read { db in
            try DBMyProfile.fetchCount(db)
        }
        let conversationCount = try await databaseManager.dbReader.read { db in
            try DBConversation.fetchCount(db)
        }
        let inboxCount = try await databaseManager.dbReader.read { db in
            try DBInbox.fetchCount(db)
        }
        let creditBalanceCount = try await databaseManager.dbReader.read { db in
            try DBCreditBalance.fetchCount(db)
        }
        #expect(contactCount == 0)
        #expect(myProfileCount == 0)
        #expect(conversationCount == 0)
        #expect(inboxCount == 0)
        #expect(creditBalanceCount == 0)
    }
}
