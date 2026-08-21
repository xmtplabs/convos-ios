import XCTest
@testable import Convos

final class ForegroundOnceGuardTests: XCTestCase {
    func testInitiallyConsumedGuardSkipsLaunchActiveAndRearmsAfterBackground() {
        let guardState = ForegroundOnceGuard(initiallyConsumed: true)

        XCTAssertFalse(guardState.tryConsume())
        guardState.reset()
        XCTAssertTrue(guardState.tryConsume())
        XCTAssertFalse(guardState.tryConsume())
    }
}
