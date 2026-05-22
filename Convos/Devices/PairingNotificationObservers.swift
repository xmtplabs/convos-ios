import Foundation

/// Holds NotificationCenter block-observer tokens and removes them when
/// this helper is deallocated. Used by `JoinerPairingSheetViewModel` so
/// the @Observable @MainActor class doesn't have to itself implement
/// `deinit` over isolated state — which Swift 6 forbids.
final class PairingNotificationObservers: @unchecked Sendable {
    private var tokens: [any NSObjectProtocol] = []
    private let lock: NSLock = NSLock()

    func add(
        for name: Notification.Name,
        queue: OperationQueue = .main,
        handler: @escaping @Sendable (Notification) -> Void
    ) {
        let token = NotificationCenter.default.addObserver(
            forName: name,
            object: nil,
            queue: queue,
            using: handler
        )
        lock.lock()
        tokens.append(token)
        lock.unlock()
    }

    deinit {
        for token in tokens {
            NotificationCenter.default.removeObserver(token)
        }
    }
}
