import ConvosCore
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

    func testAgentRelayNotificationIsSuppressedOnlyForTheVisibleProvider() {
        XCTAssertTrue(AgentRelayNotificationPresentation.shouldSuppress(
            visibleProvider: .town,
            notificationProvider: .town
        ))
        XCTAssertFalse(AgentRelayNotificationPresentation.shouldSuppress(
            visibleProvider: .town,
            notificationProvider: .tasklet
        ))
        XCTAssertFalse(AgentRelayNotificationPresentation.shouldSuppress(
            visibleProvider: .town,
            notificationProvider: nil
        ))
    }
}
