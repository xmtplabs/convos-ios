@testable import Convos
import Foundation
import XCTest

/// Covers the revoked/expired/live classification that decides whether a
/// StoreKit transaction update counts as a live local entitlement. The
/// classification feeds `hasLocalEntitlement`, which in turn decides
/// whether backend reconciliation reports an empty backend answer as
/// "activating" (entitlement awaiting confirmation) or "idle" (free).
///
/// `Transaction` is not constructible in tests, so the helper takes the
/// two relevant dates directly; these tests pin the date logic.
final class StoreKitSubscriptionServiceEntitlementTests: XCTestCase {
    private let now: Date = Date(timeIntervalSince1970: 1_780_000_000)

    func testRevokedTransactionIsNotLive() {
        let live: Bool = StoreKitSubscriptionService.isLiveEntitlement(
            revocationDate: now.addingTimeInterval(-60),
            expirationDate: now.addingTimeInterval(3_600),
            now: now
        )
        XCTAssertFalse(live, "A revoked (refunded) transaction must not count as a live entitlement even when its period has not ended")
    }

    func testExpiredTransactionIsNotLive() {
        let live: Bool = StoreKitSubscriptionService.isLiveEntitlement(
            revocationDate: nil,
            expirationDate: now.addingTimeInterval(-1),
            now: now
        )
        XCTAssertFalse(live, "An expired transaction must not count as a live entitlement")
    }

    func testActiveTransactionIsLive() {
        let live: Bool = StoreKitSubscriptionService.isLiveEntitlement(
            revocationDate: nil,
            expirationDate: now.addingTimeInterval(3_600),
            now: now
        )
        XCTAssertTrue(live, "A non-revoked transaction expiring in the future is a live entitlement")
    }

    func testNonExpiringTransactionIsLive() {
        let live: Bool = StoreKitSubscriptionService.isLiveEntitlement(
            revocationDate: nil,
            expirationDate: nil,
            now: now
        )
        XCTAssertTrue(live, "A non-revoked transaction with no expiration (non-subscription product shape) counts as live")
    }
}
