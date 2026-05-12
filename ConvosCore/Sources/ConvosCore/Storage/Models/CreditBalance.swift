import Foundation

public struct CreditBalance: Codable, Equatable, Hashable, Sendable {
    public let balance: Int
    public let monthlyGrant: Int
    public let monthlyGrantUsed: Int
    public let nextRefreshAt: Date
    public let periodLabel: String

    public init(
        balance: Int,
        monthlyGrant: Int,
        monthlyGrantUsed: Int,
        nextRefreshAt: Date,
        periodLabel: String
    ) {
        self.balance = balance
        self.monthlyGrant = monthlyGrant
        self.monthlyGrantUsed = monthlyGrantUsed
        self.nextRefreshAt = nextRefreshAt
        self.periodLabel = periodLabel
    }

    public var fractionRemaining: Double {
        guard monthlyGrant > 0 else { return 0 }
        return Double(balance) / Double(monthlyGrant)
    }

    public var isLow: Bool {
        balance > 0 && fractionRemaining <= 0.2
    }

    public var isDepleted: Bool {
        balance <= 0
    }
}
