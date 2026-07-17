import Foundation
import GRDB

struct DBCreditBalance: FetchableRecord, PersistableRecord, Codable, Hashable {
    static let databaseTableName: String = "credit_balance"

    /// Sentinel primary-key value. The table holds at most one row per install
    /// (credits are account-level and the install is single-inbox), so the row
    /// is always identified by this constant key.
    static let currentRowID: String = "current"

    enum Columns {
        static let id: Column = Column(CodingKeys.id)
        static let balance: Column = Column(CodingKeys.balance)
        static let monthlyGrant: Column = Column(CodingKeys.monthlyGrant)
        static let monthlyGrantUsed: Column = Column(CodingKeys.monthlyGrantUsed)
        static let nextRefreshAt: Column = Column(CodingKeys.nextRefreshAt)
        static let periodLabel: Column = Column(CodingKeys.periodLabel)
        static let updatedAt: Column = Column(CodingKeys.updatedAt)
    }

    let id: String
    let balance: Int
    let monthlyGrant: Int
    let monthlyGrantUsed: Int
    let nextRefreshAt: Date
    let periodLabel: String
    let updatedAt: Date
}

extension DBCreditBalance {
    init(from balance: CreditBalance, updatedAt: Date = Date()) {
        self.init(
            id: Self.currentRowID,
            balance: balance.balance,
            monthlyGrant: balance.monthlyGrant,
            monthlyGrantUsed: balance.monthlyGrantUsed,
            nextRefreshAt: balance.nextRefreshAt,
            periodLabel: balance.periodLabel,
            updatedAt: updatedAt
        )
    }

    func hydrate() -> CreditBalance {
        CreditBalance(
            balance: balance,
            monthlyGrant: monthlyGrant,
            monthlyGrantUsed: monthlyGrantUsed,
            nextRefreshAt: nextRefreshAt,
            periodLabel: periodLabel
        )
    }
}
