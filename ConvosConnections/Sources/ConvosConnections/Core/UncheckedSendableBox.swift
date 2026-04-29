import Foundation

/// Wraps a non-`Sendable` value so it can be captured by a `@Sendable` closure.
///
/// Used sparingly at the boundary with Objective-C callback APIs (like HealthKit's
/// `HKObserverQueryCompletionHandler`) where the framework guarantees thread safety
/// the compiler cannot verify.
struct UncheckedSendableBox<Value>: @unchecked Sendable {
    let value: Value

    init(_ value: Value) {
        self.value = value
    }
}

extension UncheckedSendableBox where Value == () -> Void {
    func callAsFunction() {
        value()
    }
}
