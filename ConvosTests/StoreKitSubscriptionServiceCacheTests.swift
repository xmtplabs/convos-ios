@testable import Convos
import ConvosCore
import Foundation
import XCTest

/// Covers the persisted-subscription cache added so the HOME pill doesn't
/// flicker `Basic` -> `Plus` on every cold start. The cache lives in
/// `UserDefaults.standard` under `Constant.lastKnownSubscriptionKey`; the
/// service reads it on `init` to seed `subscriptionSubject`, and writes
/// through to it on every `publish(_:)`.
///
/// We test the static `saveCachedSubscription` / `loadCachedSubscription`
/// pair directly because that's the entire cache surface. The init's
/// seeding (`CurrentValueSubject(Self.loadCachedSubscription())`) is a
/// single line of glue; testing it independently would require either
/// promoting `MockAPIClient` to public or stubbing all 59 protocol
/// methods inline. Round-trip + decode-failure coverage on the static
/// helpers is enough to keep the seeding behavior honest.
final class StoreKitSubscriptionServiceCacheTests: XCTestCase {
    /// `UserDefaults.standard` is process-wide; any leftover value would
    /// poison other tests in this file (and any others touching the same
    /// key). Clear before each test and after, regardless of which path
    /// the test exercises.
    private static let cacheKey: String = "storeKit.lastKnownSubscription"

    override func setUp() {
        super.setUp()
        UserDefaults.standard.removeObject(forKey: Self.cacheKey)
    }

    override func tearDown() {
        UserDefaults.standard.removeObject(forKey: Self.cacheKey)
        super.tearDown()
    }

    func testSaveCachedSubscription_persistsRoundTrip() {
        let original: UserSubscription = makeSubscription()
        StoreKitSubscriptionService.saveCachedSubscription(original)

        let roundTripped: UserSubscription? = StoreKitSubscriptionService.loadCachedSubscription()

        XCTAssertEqual(
            roundTripped,
            original,
            "saveCachedSubscription -> loadCachedSubscription must preserve the full UserSubscription shape so the init seeding can hand the cached value back to SwiftUI on the next launch"
        )
    }

    func testSaveCachedSubscription_nilClearsCache() {
        // Seed the cache, then clear it via the nil-write path. This is
        // the path `refreshFromEntitlements()` takes when the user no
        // longer has an entitlement (cancelled, refunded, expired); the
        // cache must follow so the next cold launch doesn't seed a stale
        // "Plus" that outlives the actual subscription.
        StoreKitSubscriptionService.saveCachedSubscription(makeSubscription())
        XCTAssertNotNil(StoreKitSubscriptionService.loadCachedSubscription())

        StoreKitSubscriptionService.saveCachedSubscription(nil)

        XCTAssertNil(
            StoreKitSubscriptionService.loadCachedSubscription(),
            "Writing nil must clear the cache; otherwise the cancelled subscription would re-flash on next launch"
        )
    }

    func testLoadCachedSubscription_emptyCacheReturnsNil() {
        // setUp already cleared the key; this just makes the contract
        // explicit so the test name documents what `loadCachedSubscription`
        // returns when there's nothing to load (vs corrupt bytes).
        XCTAssertNil(
            StoreKitSubscriptionService.loadCachedSubscription(),
            "An empty cache must return nil so init falls through to the historical pre-cache behavior"
        )
    }

    func testLoadCachedSubscription_corruptDataReturnsNil() {
        // Anyone fiddling with UserDefaults externally — or a future
        // `UserSubscription` model-shape change between app versions —
        // could leave the key holding bytes we can't decode. Must not
        // crash on startup; must surface as "no cached value" so the
        // next refresh re-establishes truth.
        UserDefaults.standard.set(Data("not a UserSubscription".utf8), forKey: Self.cacheKey)

        XCTAssertNil(
            StoreKitSubscriptionService.loadCachedSubscription(),
            "loadCachedSubscription must return nil (not throw / crash) on corrupt bytes so a malformed cache can't take down the app at launch"
        )
    }

    private func makeSubscription() -> UserSubscription {
        UserSubscription(
            tier: .plus,
            period: .monthly,
            status: .active,
            productId: "app.convos.subs.monthly",
            currentPeriodEnd: Date(timeIntervalSince1970: 1_780_000_000),
            willRenew: true,
            isInTrial: false
        )
    }
}
