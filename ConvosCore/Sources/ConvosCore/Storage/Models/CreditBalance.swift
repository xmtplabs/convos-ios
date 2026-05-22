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

    /// Fraction of the monthly grant still remaining. `nil` when there's no
    /// grant to compare against (e.g. a user with purchased top-up credits and
    /// no active subscription) — in that case "low" isn't a defined concept,
    /// callers must handle the nil explicitly instead of treating zero as
    /// "almost depleted".
    public var fractionRemaining: Double? {
        guard monthlyGrant > 0 else { return nil }
        return Double(balance) / Double(monthlyGrant)
    }

    public var isLow: Bool {
        guard let fractionRemaining else { return false }
        return balance > 0 && fractionRemaining <= 0.2
    }

    public var isDepleted: Bool {
        balance <= 0
    }
}
