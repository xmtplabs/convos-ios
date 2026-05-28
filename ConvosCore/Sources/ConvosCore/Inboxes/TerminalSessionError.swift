import Foundation

/// Marker for errors that terminate the session and cannot be recovered by
/// the foreground-retry path. The observer layer (banners, reset UI) is
/// the only path out.
///
/// `SessionStateMachine.handleRetryFromError` checks conformance and
/// short-circuits — retrying a terminal error burns retry counters and,
/// worse, can land the session in `.ready` by coincidence (e.g. a
/// transient refresh between attempts) without the reset banner ever
/// appearing. Future terminal errors can opt in with a one-line
/// conformance declaration; no changes to the `.error(any Error)` state
/// enum.
public protocol TerminalSessionError: Error {}

/// Surfaced when the network reports that this device's `installationId`
/// is no longer in the inbox's active installations — typically because
/// the user revoked this device from another paired phone's `Devices`
/// screen.
///
/// `StaleDeviceObserver` watches `SessionStateMachine` for this error
/// class and surfaces `StaleDeviceBanner`, whose only action is
/// `SessionManager.deleteAllInboxes()` followed by fresh onboarding.
public struct DeviceReplacedError: TerminalSessionError, Equatable {
    public init() {}
}
