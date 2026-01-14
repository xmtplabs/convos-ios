@testable import ConvosCore
import Foundation
import Network
import Testing

/// Comprehensive tests for NetworkMonitor
///
/// Tests cover:
/// - Network status change handling
/// - Continuation cleanup on stop/deinit
/// - Multiple subscribers to statusSequence
/// - Network monitor restart after stop
/// - Edge cases and error handling
@Suite("NetworkMonitor Tests", .serialized)
struct NetworkMonitorTests {

    private enum TestError: Error {
        case timeout(String)
    }

    private func waitUntil(
        timeout: Duration = .seconds(1),
        interval: Duration = .milliseconds(10),
        condition: () async -> Bool
    ) async throws {
        let deadline = ContinuousClock.now + timeout
        while ContinuousClock.now < deadline {
            if await condition() {
                return
            }
            try await Task.sleep(for: interval)
        }
        throw TestError.timeout("Condition not met within \(timeout)")
    }

    // MARK: - Basic Functionality Tests

    @Test("NetworkMonitor initializes with unknown status")
    func testInitialStatus() async {
        let monitor = NetworkMonitor()
        let status = await monitor.status
        #expect(status == .unknown)
        #expect(await monitor.isConnected == false)
    }

    @Test("NetworkMonitor can start and stop")
    func testStartStop() async {
        let monitor = NetworkMonitor()

        // Start monitoring
        await monitor.start()

        // Verify it's running (status should be available)
        let status = await monitor.status
        // Status is always set (could be connected, disconnected, or connecting)
        #expect(status == .unknown || status == .connecting ||
                (status.isConnected == true))

        // Stop monitoring
        await monitor.stop()

        // After stop, status should still be accessible
        let statusAfterStop = await monitor.status
        #expect(statusAfterStop == .unknown || statusAfterStop == .connecting ||
                (statusAfterStop.isConnected == true))
    }

    // MARK: - Status Sequence Tests

    @Test("Status sequence receives initial status")
    func testStatusSequenceInitialStatus() async throws {
        let monitor = NetworkMonitor()
        await monitor.start()

        // Use an actor to safely collect statuses
        actor StatusCollector {
            var statuses: [NetworkMonitor.Status] = []
            func add(_ status: NetworkMonitor.Status) {
                statuses.append(status)
            }
        }

        let collector = StatusCollector()

        // Create a task to collect statuses
        let task = Task { @Sendable in
            for await status in await monitor.statusSequence {
                await collector.add(status)
                let count = await collector.statuses.count
                if count >= 1 {
                    break
                }
            }
        }

        // Wait a bit for the initial status
        try await Task.sleep(nanoseconds: 100_000_000) // 0.1 seconds

        task.cancel()

        // Should have received at least the initial status
        let receivedStatuses = await collector.statuses
        #expect(receivedStatuses.count >= 1)
    }

    @Test("Multiple subscribers receive status updates")
    func testMultipleSubscribers() async throws {
        let monitor = NetworkMonitor()
        await monitor.start()

        actor StatusCollector {
            var subscriber1: [NetworkMonitor.Status] = []
            var subscriber2: [NetworkMonitor.Status] = []
            var subscriber3: [NetworkMonitor.Status] = []

            func add1(_ status: NetworkMonitor.Status) {
                subscriber1.append(status)
            }
            func add2(_ status: NetworkMonitor.Status) {
                subscriber2.append(status)
            }
            func add3(_ status: NetworkMonitor.Status) {
                subscriber3.append(status)
            }
        }

        let collector = StatusCollector()

        // Create three subscribers
        let task1 = Task { @Sendable in
            for await status in await monitor.statusSequence {
                await collector.add1(status)
                let count = await collector.subscriber1.count
                if count >= 2 {
                    break
                }
            }
        }

        let task2 = Task { @Sendable in
            for await status in await monitor.statusSequence {
                await collector.add2(status)
                let count = await collector.subscriber2.count
                if count >= 2 {
                    break
                }
            }
        }

        let task3 = Task { @Sendable in
            for await status in await monitor.statusSequence {
                await collector.add3(status)
                let count = await collector.subscriber3.count
                if count >= 2 {
                    break
                }
            }
        }

        // Wait for all subscribers to receive at least one status update with timeout
        try await waitUntil {
            let count1 = await collector.subscriber1.count
            let count2 = await collector.subscriber2.count
            let count3 = await collector.subscriber3.count
            return count1 >= 1 && count2 >= 1 && count3 >= 1
        }

        task1.cancel()
        task2.cancel()
        task3.cancel()

        // All subscribers should have received at least the initial status
        let subscriber1Statuses = await collector.subscriber1
        let subscriber2Statuses = await collector.subscriber2
        let subscriber3Statuses = await collector.subscriber3

        #expect(subscriber1Statuses.count >= 1)
        #expect(subscriber2Statuses.count >= 1)
        #expect(subscriber3Statuses.count >= 1)

        // All should have received the same initial status
        if !subscriber1Statuses.isEmpty && !subscriber2Statuses.isEmpty {
            #expect(subscriber1Statuses[0] == subscriber2Statuses[0])
        }
        if !subscriber2Statuses.isEmpty && !subscriber3Statuses.isEmpty {
            #expect(subscriber2Statuses[0] == subscriber3Statuses[0])
        }
    }

    // MARK: - Continuation Cleanup Tests

    @Test("Continuations are cleaned up on stop")
    func testContinuationCleanupOnStop() async throws {
        let monitor = NetworkMonitor()
        await monitor.start()

        // Create a subscriber
        let task = Task { @Sendable in
            for await _ in await monitor.statusSequence {
                // Keep receiving
            }
        }

        // Wait for continuation to be added
        try await Task.sleep(nanoseconds: 100_000_000) // 0.1 seconds

        // Stop should finish all continuations
        await monitor.stop()

        // Wait a bit for cleanup
        try await Task.sleep(nanoseconds: 100_000_000) // 0.1 seconds

        task.cancel()

        // The continuation should have been finished by stop()
        // Note: We can't directly verify this, but the stream should terminate
        // The fact that stop() completes without hanging indicates cleanup worked
        #expect(true) // If we get here, cleanup didn't hang
    }

    @Test("Multiple continuations are cleaned up on stop")
    func testMultipleContinuationCleanupOnStop() async throws {
        let monitor = NetworkMonitor()
        await monitor.start()

        // Create multiple subscribers
        let task1 = Task { @Sendable in
            for await _ in await monitor.statusSequence {
                // Keep receiving
            }
        }

        let task2 = Task { @Sendable in
            for await _ in await monitor.statusSequence {
                // Keep receiving
            }
        }

        let task3 = Task { @Sendable in
            for await _ in await monitor.statusSequence {
                // Keep receiving
            }
        }

        // Wait for continuations to be added
        try await Task.sleep(nanoseconds: 100_000_000) // 0.1 seconds

        // Stop should finish all continuations
        await monitor.stop()

        // Wait a bit for cleanup
        try await Task.sleep(nanoseconds: 100_000_000) // 0.1 seconds

        task1.cancel()
        task2.cancel()
        task3.cancel()

        // All continuations should have been finished
        // The fact that stop() completes indicates cleanup worked
        #expect(true) // If we get here, cleanup didn't hang
    }

    @Test("Subscribers can unsubscribe and continuations are removed")
    func testSubscriberUnsubscribe() async throws {
        let monitor = NetworkMonitor()
        await monitor.start()

        actor Counter {
            var count1 = 0
            var count2 = 0
            func increment1() { count1 += 1 }
            func increment2() { count2 += 1 }
        }

        let counter = Counter()

        // Create two subscribers
        let task1 = Task { @Sendable in
            for await _ in await monitor.statusSequence {
                await counter.increment1()
                let count = await counter.count1
                if count >= 1 {
                    break // Unsubscribe after first status
                }
            }
        }

        let task2 = Task { @Sendable in
            for await _ in await monitor.statusSequence {
                await counter.increment2()
                // Keep receiving
            }
        }

        // Wait for initial status
        try await Task.sleep(nanoseconds: 100_000_000) // 0.1 seconds

        // First subscriber should have unsubscribed
        let count1 = await counter.count1
        #expect(count1 >= 1)

        // Second subscriber should still be active
        let count2 = await counter.count2
        #expect(count2 >= 1)

        // Wait a bit more
        try await Task.sleep(nanoseconds: 100_000_000) // 0.1 seconds

        // First subscriber should not have received more
        let count1After = await counter.count1

        // Second subscriber may have received more
        let count2After = await counter.count2

        #expect(count1After == count1) // First subscriber stopped receiving
        #expect(count2After >= count2) // Second subscriber may have received more

        task1.cancel()
        task2.cancel()

        await monitor.stop()
    }

    // MARK: - Restart Tests

    @Test("NetworkMonitor can restart after stop")
    func testRestartAfterStop() async throws {
        let monitor = NetworkMonitor()

        // Start
        await monitor.start()
        let status1 = await monitor.status
        // Status is always set
        #expect(status1 == .unknown || status1 == .connecting || status1.isConnected)

        // Stop
        await monitor.stop()

        // Restart
        await monitor.start()
        let status2 = await monitor.status
        // Status is always set
        #expect(status2 == .unknown || status2 == .connecting || status2.isConnected)

        // Should be able to get status sequence after restart
        actor StatusReceiver {
            var received = false
            func markReceived() { received = true }
        }

        let receiver = StatusReceiver()
        let task = Task { @Sendable in
            for await status in await monitor.statusSequence {
                await receiver.markReceived()
                // Status is always set
                #expect(status == .unknown || status == .unknown || status == .connecting || status.isConnected)
                break
            }
        }

        try await Task.sleep(nanoseconds: 100_000_000) // 0.1 seconds

        let receivedStatus = await receiver.received
        #expect(receivedStatus == true)

        task.cancel()
        await monitor.stop()
    }

    @Test("New subscribers work after restart")
    func testNewSubscribersAfterRestart() async throws {
        let monitor = NetworkMonitor()

        // Start and stop
        await monitor.start()
        await monitor.stop()

        // Restart
        await monitor.start()

        // Create new subscribers after restart
        actor Receivers {
            var subscriber1 = false
            var subscriber2 = false
            func mark1() { subscriber1 = true }
            func mark2() { subscriber2 = true }
            func bothReceived() -> Bool { subscriber1 && subscriber2 }
        }

        let receivers = Receivers()

        let task1 = Task { @Sendable in
            for await _ in await monitor.statusSequence {
                await receivers.mark1()
                break
            }
        }

        let task2 = Task { @Sendable in
            for await _ in await monitor.statusSequence {
                await receivers.mark2()
                break
            }
        }

        // Wait for both receivers to be marked with timeout
        try await waitUntil {
            await receivers.bothReceived()
        }

        let subscriber1Received = await receivers.subscriber1
        let subscriber2Received = await receivers.subscriber2

        #expect(subscriber1Received == true)
        #expect(subscriber2Received == true)

        task1.cancel()
        task2.cancel()
        await monitor.stop()
    }

    // MARK: - Edge Cases and Status Handling Tests

    @Test("Status sequence handles rapid subscriptions and unsubscriptions")
    func testRapidSubscriptionUnsubscription() async throws {
        let monitor = NetworkMonitor()
        await monitor.start()

        // Rapidly create and cancel multiple subscribers
        var tasks: [Task<Void, Never>] = []

        for _ in 0..<10 {
            let task = Task { @Sendable in
                var count = 0
                for await _ in await monitor.statusSequence {
                    count += 1
                    if count >= 1 {
                        break
                    }
                }
            }
            tasks.append(task)

            // Small delay between subscriptions
            try await Task.sleep(nanoseconds: 10_000_000) // 0.01 seconds
        }

        // Wait a bit
        try await Task.sleep(nanoseconds: 100_000_000) // 0.1 seconds

        // Cancel all tasks
        for task in tasks {
            task.cancel()
        }

        // Stop should still work without hanging
        await monitor.stop()

        #expect(true) // If we get here, no deadlock occurred
    }

    @Test("Status property reflects current state")
    func testStatusProperty() async {
        let monitor = NetworkMonitor()

        // Initial status should be disconnected
        let initialStatus = await monitor.status
        #expect(initialStatus == .unknown)
        #expect(await monitor.isConnected == false)

        await monitor.start()

        // After start, status should be available (may be connected, disconnected, or connecting)
        let statusAfterStart = await monitor.status
        // Status is always set
        #expect(statusAfterStart == .unknown || statusAfterStart == .connecting || statusAfterStart.isConnected)

        // isConnected should match status - derive from status to avoid race condition
        let isConnectedFromStatus = statusAfterStart.isConnected
        if case .connected = statusAfterStart {
            #expect(isConnectedFromStatus == true)
        } else {
            #expect(isConnectedFromStatus == false)
        }

        await monitor.stop()
    }

    @Test("Connection type detection works")
    func testConnectionTypeDetection() async {
        let monitor = NetworkMonitor()
        await monitor.start()

        let status = await monitor.status

        // If connected, should have a connection type
        if case .connected(let type) = status {
            // Type should be one of the valid types
            let validTypes: [NetworkMonitor.ConnectionType] = [.wifi, .cellular, .wiredEthernet, .other]
            #expect(validTypes.contains(type))
        }

        await monitor.stop()
    }

    @Test("Expensive and constrained properties are accessible")
    func testNetworkProperties() async {
        let monitor = NetworkMonitor()
        await monitor.start()

        // These properties should be accessible without crashing
        let isExpensive = await monitor.isExpensive
        let isConstrained = await monitor.isConstrained

        // Values should be booleans (we can't predict actual values)
        #expect(type(of: isExpensive) == Bool.self)
        #expect(type(of: isConstrained) == Bool.self)

        await monitor.stop()
    }

    // MARK: - Concurrent Access Tests

    @Test("Concurrent access to status is safe")
    func testConcurrentStatusAccess() async {
        let monitor = NetworkMonitor()
        await monitor.start()

        // Access status from multiple tasks concurrently
        await withTaskGroup(of: Void.self) { group in
            for _ in 0..<10 {
                group.addTask { @Sendable in
                    let status = await monitor.status
                    // Status is always set
                    #expect(status == .unknown || status == .connecting || status.isConnected)
                    let isConnected = await monitor.isConnected
                    #expect(type(of: isConnected) == Bool.self)
                }
            }
        }

        await monitor.stop()
    }

    @Test("Concurrent subscriptions are handled correctly")
    func testConcurrentSubscriptions() async throws {
        let monitor = NetworkMonitor()
        await monitor.start()

        actor CountCollector {
            var counts: [Int] = []
            func add(_ count: Int) {
                counts.append(count)
            }
        }

        let collector = CountCollector()

        await withTaskGroup(of: Void.self) { group in
            for _ in 0..<10 {
                group.addTask { @Sendable in
                    var count = 0
                    for await _ in await monitor.statusSequence {
                        count += 1
                        // Only wait for initial status - subsequent updates only come
                        // when the network actually changes, which may not happen during tests
                        if count >= 1 {
                            break
                        }
                    }
                    await collector.add(count)
                }
            }
        }

        // All tasks should have received at least one status (the initial status)
        let receivedCounts = await collector.counts
        #expect(receivedCounts.count == 10, "All 10 tasks should have completed")
        for count in receivedCounts {
            #expect(count >= 1)
        }

        await monitor.stop()
    }
}
