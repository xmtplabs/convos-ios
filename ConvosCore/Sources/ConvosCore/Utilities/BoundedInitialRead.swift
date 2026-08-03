import Foundation

/// Runs a blocking read on a background queue while the main thread waits a
/// bounded amount of time for the result.
///
/// View models used to run their first database read synchronously in `init`
/// so content is on screen in the very first rendered frame. That read walks
/// SQLite overflow pages for large `message.text` values and contends on the
/// shared page-cache mutex with background writers, which produced multi-
/// second main-thread hangs in production (Sentry CONVOS-IOS-4A). Making the
/// read fully asynchronous fixes the hang but guarantees an empty first
/// frame on every open.
///
/// This helper keeps both properties: the read itself always runs off the
/// main thread, and the main thread waits for it only up to `deadline`. In
/// the common case the read finishes well inside the deadline and the caller
/// applies the result synchronously, so the first frame is fully populated.
/// In the pathological case the wait gives up (an imperceptible pause, far
/// below hang thresholds), the view renders without the data, and `late`
/// delivers the result on the main actor as soon as the read completes.
public enum BoundedInitialRead {
    private final class ResultBox<T>: @unchecked Sendable {
        private let lock: NSLock = NSLock()
        private var value: T?
        private var timedOut: Bool = false

        func store(_ newValue: T?) -> Bool {
            lock.lock()
            defer { lock.unlock() }
            value = newValue
            return timedOut
        }

        func take(markTimedOut: Bool) -> T? {
            lock.lock()
            defer { lock.unlock() }
            if markTimedOut {
                timedOut = true
            }
            return value
        }
    }

    /// Returns the read's value when it completes within `deadline`,
    /// otherwise returns nil and later invokes `late` with the value on the
    /// main queue. `read` executes exactly once, always off the caller's
    /// thread; exactly one of the synchronous return or `late` delivers a
    /// non-nil result.
    public static func prime<T>(
        deadline: DispatchTimeInterval = .milliseconds(50),
        read: @escaping @Sendable () -> T?,
        late: @escaping @MainActor (T) -> Void
    ) -> T? {
        let box: ResultBox<T> = ResultBox()
        let semaphore = DispatchSemaphore(value: 0)
        DispatchQueue.global(qos: .userInitiated).async {
            let deliverLate = box.store(read())
            semaphore.signal()
            if deliverLate {
                DispatchQueue.main.async {
                    if let value = box.take(markTimedOut: false) {
                        MainActor.assumeIsolated {
                            late(value)
                        }
                    }
                }
            }
        }
        if semaphore.wait(timeout: .now() + deadline) == .success {
            return box.take(markTimedOut: false)
        }
        return box.take(markTimedOut: true)
    }
}
