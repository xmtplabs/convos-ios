@testable import ConvosCore
import Foundation
import Testing

/// Coverage for the per-conversation prepare time budget in
/// `BatchCatchUp`. The batch-level skip semantics (a timed-out or
/// failing conversation drops out of the batch without aborting it)
/// are exercised through `withTimeout`, which is the exact racing
/// primitive `prepareAll` wraps each conversation in.
@Suite("Batch Catch-Up Timeout Tests")
struct BatchCatchUpTimeoutTests {
    @Test("Operation finishing under the budget returns its value")
    func fastOperationReturns() async throws {
        let value = try await BatchCatchUp.withTimeout(seconds: 5) { 42 }
        #expect(value == 42)
    }

    @Test("Operation exceeding the budget throws the timeout error")
    func slowOperationTimesOut() async {
        await #expect(throws: BatchCatchUpPrepareTimeout.self) {
            try await BatchCatchUp.withTimeout(seconds: 0.05) { () -> Int in
                try await Task.sleep(nanoseconds: 5_000_000_000)
                return 1
            }
        }
    }

    @Test("Operation errors propagate unchanged, not as timeouts")
    func operationErrorPropagates() async {
        struct Boom: Error {}
        await #expect(throws: Boom.self) {
            try await BatchCatchUp.withTimeout(seconds: 5) { () -> Int in
                throw Boom()
            }
        }
    }

    @Test("The losing operation is cancelled when the deadline fires")
    func operationIsCancelledOnTimeout() async throws {
        let cancelled = CancellationProbe()
        _ = try? await BatchCatchUp.withTimeout(seconds: 0.05) { () -> Int in
            do {
                try await Task.sleep(nanoseconds: 5_000_000_000)
            } catch is CancellationError {
                await cancelled.mark()
                throw CancellationError()
            }
            return 1
        }
        // The cancellation lands asynchronously after the race resolves.
        for _ in 0..<100 where await !cancelled.isMarked {
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        #expect(await cancelled.isMarked)
    }
}

private actor CancellationProbe {
    private(set) var isMarked: Bool = false

    func mark() {
        isMarked = true
    }
}
