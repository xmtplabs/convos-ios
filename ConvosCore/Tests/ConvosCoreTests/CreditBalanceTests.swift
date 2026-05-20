@testable import ConvosCore
import Foundation
import Testing

struct CreditBalanceTests {
    private func make(
        balance: Int,
        monthlyGrant: Int,
        monthlyGrantUsed: Int = 0
    ) -> CreditBalance {
        CreditBalance(
            balance: balance,
            monthlyGrant: monthlyGrant,
            monthlyGrantUsed: monthlyGrantUsed,
            nextRefreshAt: Date(),
            periodLabel: "Test"
        )
    }

    // MARK: - fractionRemaining

    @Test func fractionRemaining_isNilWhenMonthlyGrantIsZero() {
        let balance: CreditBalance = make(balance: 500, monthlyGrant: 0)
        #expect(balance.fractionRemaining == nil)
    }

    @Test func fractionRemaining_dividesBalanceByGrant() {
        let balance: CreditBalance = make(balance: 300, monthlyGrant: 1_500)
        #expect(balance.fractionRemaining == 0.2)
    }

    @Test func fractionRemaining_isOneWhenBalanceMatchesGrant() {
        let balance: CreditBalance = make(balance: 1_500, monthlyGrant: 1_500)
        #expect(balance.fractionRemaining == 1.0)
    }

    // MARK: - isLow

    @Test func isLow_falseWhenNoGrant() {
        // A user with purchased top-up credits and no active subscription:
        // monthlyGrant == 0 must not light up the low-balance warning UI.
        let balance: CreditBalance = make(balance: 500, monthlyGrant: 0)
        #expect(balance.isLow == false)
    }

    @Test func isLow_falseWhenBalanceIsZero() {
        let balance: CreditBalance = make(balance: 0, monthlyGrant: 1_500)
        #expect(balance.isLow == false, "Zero balance is depleted, not low")
    }

    @Test func isLow_trueAtTwentyPercentBoundary() {
        let balance: CreditBalance = make(balance: 300, monthlyGrant: 1_500)
        #expect(balance.isLow == true, "20% exactly should count as low")
    }

    @Test func isLow_falseAboveTwentyPercent() {
        let balance: CreditBalance = make(balance: 301, monthlyGrant: 1_500)
        #expect(balance.isLow == false)
    }

    @Test func isLow_trueBelowTwentyPercent() {
        let balance: CreditBalance = make(balance: 100, monthlyGrant: 1_500)
        #expect(balance.isLow == true)
    }

    // MARK: - isDepleted

    @Test func isDepleted_trueWhenZero() {
        let balance: CreditBalance = make(balance: 0, monthlyGrant: 1_500)
        #expect(balance.isDepleted == true)
    }

    @Test func isDepleted_trueWhenNegative() {
        // Defensive: backend over-consumption could theoretically race a balance
        // below zero. Treat it as depleted, not "negative is fine".
        let balance: CreditBalance = make(balance: -50, monthlyGrant: 1_500)
        #expect(balance.isDepleted == true)
    }

    @Test func isDepleted_falseWhenPositive() {
        let balance: CreditBalance = make(balance: 1, monthlyGrant: 1_500)
        #expect(balance.isDepleted == false)
    }

    @Test func depletedAndLowAreMutuallyExclusive() {
        // Balance 0 is depleted, not low. The UI uses isLow || isDepleted and
        // expects exactly one of them to be true for any depleted balance —
        // showing "low" copy on a zero-balance card is wrong.
        let depleted: CreditBalance = make(balance: 0, monthlyGrant: 1_500)
        #expect(depleted.isDepleted == true)
        #expect(depleted.isLow == false)
    }
}
