import Foundation

/// A counting semaphore for structured concurrency, used to bound how many
/// tasks run a section at once (e.g. parallel downloads).
///
/// Waiters resume in FIFO order. Waiting is not cancellation-aware: a
/// cancelled task still waits for its slot, so callers whose work is
/// cancellable should check `Task.isCancelled` inside the slot.
actor AsyncSemaphore {
    private let width: Int
    private var active: Int = 0
    private var waiters: [CheckedContinuation<Void, Never>] = []

    init(width: Int) {
        self.width = max(1, width)
    }

    /// Run `body` once a slot is free, releasing the slot when it returns or throws.
    func withSlot<T: Sendable>(_ body: @Sendable () async throws -> T) async rethrows -> T {
        await acquire()
        defer { release() }
        return try await body()
    }

    private func acquire() async {
        if active < width {
            active += 1
            return
        }
        await withCheckedContinuation { continuation in
            waiters.append(continuation)
        }
    }

    private func release() {
        if waiters.isEmpty {
            active -= 1
        } else {
            // Hand the slot directly to the next waiter; active is unchanged.
            waiters.removeFirst().resume()
        }
    }
}
