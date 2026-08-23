import ConvosCore
import XCTest
@testable import Convos

@MainActor
final class BootSettlementMonitorTests: XCTestCase {
    func testSettlesImmediatelyWhenAlreadyReadyAtBind() async throws {
        let manager = MockSessionStateManager()
        let readyResult = try await manager.waitForInboxReadyResult()
        manager.setState(.ready(readyResult))

        let monitor = BootSettlementMonitor()
        monitor.bind(to: manager)

        XCTAssertTrue(monitor.isSettled)
    }

    func testSettlesWhenReadyArrivesAfterBind() async throws {
        let manager = MockSessionStateManager(initialState: .authorizing(inboxId: "inbox"))
        let monitor = BootSettlementMonitor()
        monitor.bind(to: manager)

        XCTAssertFalse(monitor.isSettled)

        let readyResult = try await manager.waitForInboxReadyResult()
        manager.setState(.ready(readyResult))
        await waitFor { monitor.isSettled }

        XCTAssertTrue(monitor.isSettled)
    }

    func testSettlesViaFallbackTimeoutWhenReadyNeverArrives() async {
        let manager = MockSessionStateManager(initialState: .authorizing(inboxId: "inbox"))
        let monitor = BootSettlementMonitor()
        monitor.bind(to: manager, fallbackTimeout: 0.05)

        XCTAssertFalse(monitor.isSettled)

        await waitFor { monitor.isSettled }
        XCTAssertTrue(monitor.isSettled)
    }

    func testStaysSettledAfterLaterNonReadyStates() async throws {
        let manager = MockSessionStateManager(initialState: .authorizing(inboxId: "inbox"))
        let monitor = BootSettlementMonitor()
        monitor.bind(to: manager)

        let readyResult = try await manager.waitForInboxReadyResult()
        manager.setState(.ready(readyResult))
        await waitFor { monitor.isSettled }

        manager.setState(.backgrounded(readyResult))
        manager.setState(.authorizing(inboxId: "inbox"))
        await Task.yield()

        XCTAssertTrue(monitor.isSettled)
    }

    func testRebindBeforeSettlingReplacesObservation() async throws {
        let first = MockSessionStateManager(initialState: .authorizing(inboxId: "inbox"))
        let second = MockSessionStateManager(initialState: .authorizing(inboxId: "inbox"))
        let monitor = BootSettlementMonitor()
        monitor.bind(to: first)
        monitor.bind(to: second)

        let readyResult = try await first.waitForInboxReadyResult()
        first.setState(.ready(readyResult))
        await waitFor(timeout: 0.2) { monitor.isSettled }
        XCTAssertFalse(monitor.isSettled, "A replaced observation must not settle the monitor")

        second.setState(.ready(readyResult))
        await waitFor { monitor.isSettled }
        XCTAssertTrue(monitor.isSettled)
    }

    /// Polls until the condition holds, yielding the main actor between
    /// checks so state-stream handlers can run.
    private func waitFor(
        timeout: TimeInterval = 2,
        _ condition: () -> Bool
    ) async {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition(), Date() < deadline {
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
    }
}
