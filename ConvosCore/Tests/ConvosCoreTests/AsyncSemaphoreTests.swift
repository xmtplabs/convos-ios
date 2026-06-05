@testable import ConvosCore
import Foundation
import Testing

/// Tracks how many tasks are inside a section at once.
private actor ConcurrencyCounter {
    private(set) var current: Int = 0
    private(set) var peak: Int = 0
    private(set) var completed: Int = 0

    func enter() {
        current += 1
        peak = max(peak, current)
    }

    func exit() {
        current -= 1
        completed += 1
    }
}

struct AsyncSemaphoreTests {
    @Test func boundsConcurrencyToWidth() async {
        let semaphore = AsyncSemaphore(width: 3)
        let counter = ConcurrencyCounter()

        await withTaskGroup(of: Void.self) { group in
            for _ in 0..<20 {
                group.addTask {
                    await semaphore.withSlot {
                        await counter.enter()
                        try? await Task.sleep(nanoseconds: 5_000_000)
                        await counter.exit()
                    }
                }
            }
        }

        #expect(await counter.peak <= 3)
        #expect(await counter.completed == 20)
        #expect(await counter.current == 0)
    }

    @Test func releasesSlotWhenBodyThrows() async throws {
        struct TestError: Error {}
        let semaphore = AsyncSemaphore(width: 1)

        await #expect(throws: TestError.self) {
            try await semaphore.withSlot { throw TestError() }
        }

        // The slot must be free again after the failure.
        let value = await semaphore.withSlot { 42 }
        #expect(value == 42)
    }

    @Test func returnsBodyValue() async {
        let semaphore = AsyncSemaphore(width: 2)

        let value = await semaphore.withSlot { "result" }

        #expect(value == "result")
    }
}
