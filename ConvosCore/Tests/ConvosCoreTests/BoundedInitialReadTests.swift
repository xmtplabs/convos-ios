@testable import ConvosCore
import XCTest

@MainActor
final class BoundedInitialReadTests: XCTestCase {
    func testFastReadReturnsSynchronouslyAndNeverDeliversLate() {
        let lateDelivery = expectation(description: "late closure must not fire")
        lateDelivery.isInverted = true

        let primed: Int? = BoundedInitialRead.prime(
            deadline: .milliseconds(500),
            read: { 42 },
            late: { _ in lateDelivery.fulfill() }
        )

        XCTAssertEqual(primed, 42, "A read that beats the deadline should return synchronously")
        wait(for: [lateDelivery], timeout: 0.5)
    }

    func testSlowReadMissesDeadlineAndDeliversLateOnMain() {
        let lateDelivery = expectation(description: "late closure fires with the value")
        var lateValue: Int?

        let primed: Int? = BoundedInitialRead.prime(
            deadline: .milliseconds(20),
            read: { () -> Int? in
                Thread.sleep(forTimeInterval: 0.2)
                return 7
            },
            late: { value in
                lateValue = value
                XCTAssertTrue(Thread.isMainThread, "Late delivery must land on the main thread")
                lateDelivery.fulfill()
            }
        )

        XCTAssertNil(primed, "A read slower than the deadline should return nil synchronously")
        wait(for: [lateDelivery], timeout: 2.0)
        XCTAssertEqual(lateValue, 7)
    }

    func testValueIsDeliveredExactlyOnce() {
        // Sweep delays across the deadline boundary so some runs return
        // synchronously and others deliver late; each must deliver once.
        for delayMs in [0, 10, 25, 40] {
            let counter = DeliveryCounter()
            let delivered = expectation(description: "delivered once for delay \(delayMs)ms")

            let primed: Int? = BoundedInitialRead.prime(
                deadline: .milliseconds(25),
                read: { () -> Int? in
                    Thread.sleep(forTimeInterval: Double(delayMs) / 1000)
                    return delayMs
                },
                late: { _ in
                    counter.increment()
                    delivered.fulfill()
                }
            )

            if primed != nil {
                counter.increment()
                delivered.fulfill()
            }
            wait(for: [delivered], timeout: 2.0)
            // Allow any straggling (incorrect) second delivery to surface.
            RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.1))
            XCTAssertEqual(counter.count, 1, "Exactly one delivery expected for delay \(delayMs)ms")
        }
    }

    func testNilReadResultDeliversNothing() {
        let lateDelivery = expectation(description: "late closure must not fire for nil result")
        lateDelivery.isInverted = true

        let primed: Int? = BoundedInitialRead.prime(
            deadline: .milliseconds(20),
            read: { () -> Int? in
                Thread.sleep(forTimeInterval: 0.1)
                return nil
            },
            late: { _ in lateDelivery.fulfill() }
        )

        XCTAssertNil(primed)
        wait(for: [lateDelivery], timeout: 0.5)
    }

    private final class DeliveryCounter: @unchecked Sendable {
        private let lock: NSLock = NSLock()
        private var _count: Int = 0

        var count: Int {
            lock.lock()
            defer { lock.unlock() }
            return _count
        }

        func increment() {
            lock.lock()
            defer { lock.unlock() }
            _count += 1
        }
    }
}
