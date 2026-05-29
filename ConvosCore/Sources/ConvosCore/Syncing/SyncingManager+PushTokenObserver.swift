import Foundation

/// D14 wiring: bring an APNS token rotation through to push topic reconcile
/// even when the conversation set is unchanged.
///
/// Without this, the iOS-side hash cache (D8) keeps happily debouncing because
/// everything except the token hashes the same; the XMTP notifications server
/// keeps the old deliveryMechanism and stops delivering pushes. The cache key
/// includes the token sha so this dispatch produces a miss naturally and the
/// reconcile actually hits the wire.
///
/// Lives in its own extension file so it can grow with documentation without
/// pushing the primary `SyncingManager` body past the SwiftLint type-body cap.
extension SyncingManager {
    func installPushTokenObserver() {
        let pushTokenObserver = NotificationCenter.default.addObserver(
            forName: .convosPushTokenDidChange,
            object: nil,
            queue: nil
        ) { [weak self] _ in
            Task { [weak self] in
                await self?.reconcileAfterTokenChange()
            }
        }
        notificationObservers.append(pushTokenObserver)
    }

    func reconcileAfterTokenChange() async {
        let activeParams: SyncClientParams?
        switch _state {
        case .idle, .stopping, .error: activeParams = nil
        case .starting(let params, _), .ready(let params), .paused(let params): activeParams = params
        }
        guard let params = activeParams else {
            Log.debug("convosPushTokenDidChange ignored - no active SyncClientParams")
            return
        }
        await streamProcessor.reconcilePushSubscriptions(params: params, context: "after token change")
    }

    /// Stack 2 T17 "Force Reconcile" button: clear the iOS cache, then
    /// drive a full reconcile through the wire regardless of conversation
    /// count. Bypasses the D3 count-gate (which exists specifically to
    /// suppress redundant reconciles) by going straight at
    /// streamProcessor.reconcilePushSubscriptions. Skips if there's no
    /// active SyncClientParams (idle / stopping / error state).
    func forceReconcilePushTopics() async {
        await streamProcessor.clearPushSubscriptionCache()
        let activeParams: SyncClientParams?
        switch _state {
        case .idle, .stopping, .error: activeParams = nil
        case .starting(let params, _), .ready(let params), .paused(let params): activeParams = params
        }
        guard let params = activeParams else {
            Log.warning("forceReconcilePushTopics: no active SyncClientParams (state: \(_state))")
            return
        }
        await streamProcessor.reconcilePushSubscriptions(params: params, context: "forced from debug screen")
    }
}
