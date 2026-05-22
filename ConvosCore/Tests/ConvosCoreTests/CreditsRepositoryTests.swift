@testable import ConvosCore
import Foundation
import GRDB
import Testing

@Suite("CreditsRepository Tests", .serialized)
struct CreditsRepositoryTests {
    @Test("currentBalance returns nil when the table is empty")
    func testEmptyTable() throws {
        let dbManager = MockDatabaseManager.makeTestDatabase()
        let repo: CreditsRepository = CreditsRepository(databaseReader: dbManager.dbReader)

        #expect(try repo.currentBalance() == nil)
    }

    @Test("currentBalance hydrates the row matching the sentinel ID")
    func testCurrentBalanceMatchesSentinelRow() throws {
        let dbManager = MockDatabaseManager.makeTestDatabase()
        let nextRefresh: Date = Date(timeIntervalSince1970: 1_700_000_000)
        let balance: CreditBalance = CreditBalance(
            balance: 1_234,
            monthlyGrant: 2_000,
            monthlyGrantUsed: 766,
            nextRefreshAt: nextRefresh,
            periodLabel: "Apr 1 – May 1"
        )

        try dbManager.dbWriter.write { db in
            try DBCreditBalance(from: balance, updatedAt: Date()).save(db)
        }

        let repo: CreditsRepository = CreditsRepository(databaseReader: dbManager.dbReader)
        let fetched: CreditBalance? = try repo.currentBalance()

        #expect(fetched == balance)
    }

    @Test("upserting the sentinel row twice keeps a single row reflecting the latest write")
    func testUpsertOverwritesSentinelRow() throws {
        let dbManager = MockDatabaseManager.makeTestDatabase()
        let first: CreditBalance = CreditBalance(
            balance: 100,
            monthlyGrant: 500,
            monthlyGrantUsed: 400,
            nextRefreshAt: Date(timeIntervalSince1970: 1_700_000_000),
            periodLabel: "P1"
        )
        let second: CreditBalance = CreditBalance(
            balance: 250,
            monthlyGrant: 500,
            monthlyGrantUsed: 250,
            nextRefreshAt: Date(timeIntervalSince1970: 1_700_500_000),
            periodLabel: "P2"
        )

        try dbManager.dbWriter.write { db in
            try DBCreditBalance(from: first).save(db)
            try DBCreditBalance(from: second).save(db)
        }

        let rowCount: Int = try dbManager.dbReader.read { db in
            try DBCreditBalance.fetchCount(db)
        }
        #expect(rowCount == 1)

        let repo: CreditsRepository = CreditsRepository(databaseReader: dbManager.dbReader)
        #expect(try repo.currentBalance() == second)
    }
}
