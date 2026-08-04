import Foundation

/// Counts app background transitions so wall-clock perf measurements can
/// distinguish genuinely slow work from a timer that spanned an iOS app
/// suspension (the wall clock keeps running while the process is frozen,
/// which once produced a 216s `conversation.sync` sample that was really
/// ~5s of work around a 3.5 minute suspension).
public final class AppBackgroundTransitionCounter: @unchecked Sendable {
    public static let shared: AppBackgroundTransitionCounter = AppBackgroundTransitionCounter()

    private let lock: NSLock = NSLock()
    private var transitionCount: Int = 0

    public var count: Int {
        lock.withLock { transitionCount }
    }

    public func record() {
        lock.withLock { transitionCount += 1 }
    }
}
