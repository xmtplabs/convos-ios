import Foundation

/// Marker for errors that terminate the session and cannot be recovered by
/// the foreground-retry path. The observer layer (banners, reset UI) is
/// the only path out.
///
/// `SessionStateMachine.handleRetryFromError` checks conformance and
/// short-circuits — retrying a terminal error burns retry counters and,
/// worse, can land the session in `.ready` by coincidence without the
/// reset banner ever appearing. Future terminal errors can opt in with a
/// one-line conformance declaration; no changes to the `.error(any Error)`
/// state enum.
public protocol TerminalSessionError: Error {}

/// Surfaced when the network reports that this device's `installationId`
/// is no longer in the inbox's active installations — usually because the
/// user ran `Restore from backup` on a different device, which revoked
/// every other installation in the tail of its flow.
///
/// `StaleDeviceBanner` observes this error class via
/// `SessionStateObserver` and offers the user `SessionManager
/// .deleteAllInboxes()` as the only path out.
public struct DeviceReplacedError: TerminalSessionError, Equatable {
    public init() {}
}
