import Foundation

/// Runs `operation`, retrying on a thrown error up to `maxAttempts` total
/// with exponential backoff (via `TimeInterval.calculateExponentialBackoff`)
/// between attempts. Returns as soon as an attempt succeeds; re-throws the
/// last error once every attempt has failed.
///
/// Cancellation-aware: a cancelled task stops retrying and re-throws the
/// most recent error rather than sleeping again.
func withExponentialBackoffRetry<T>(
    maxAttempts: Int = 3,
    operation: () async throws -> T
) async throws -> T {
    var attempt: Int = 0
    while true {
        do {
            return try await operation()
        } catch {
            attempt += 1
            if attempt >= maxAttempts || Task.isCancelled {
                throw error
            }
            let delay: TimeInterval = .calculateExponentialBackoff(for: attempt - 1)
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
        }
    }
}
