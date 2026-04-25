import Foundation

/// Single-shot wrapper around an `onClose` closure used by the DTU
/// polling-based stream emulators (`DTUMessagingGroup.streamMessages`,
/// `DTUMessagingConversations.streamAll` / `streamAllMessages`).
///
/// `MessagingStream`'s `onClose` contract — established by the XMTPiOS
/// adapter — is "called exactly once when the stream terminates"; the
/// SyncingManager logs at debug level on each `onClose`, and a few
/// state-machine paths take the callback as an external "stream is
/// quiescent" signal. Polling is wired so cancel paths can run
/// concurrently (continuation termination, inner task cancel, caller
/// cancel-and-await) — without a guard a slow consumer can fire the
/// closure twice. `NSLock` + a flag is enough; we don't need atomics.
final class OnCloseOnce: @unchecked Sendable {
    private let lock = NSLock()
    private var closure: (@Sendable () -> Void)?

    init(_ closure: (@Sendable () -> Void)?) {
        self.closure = closure
    }

    func fire() {
        lock.lock()
        let captured = closure
        closure = nil
        lock.unlock()
        captured?()
    }
}
