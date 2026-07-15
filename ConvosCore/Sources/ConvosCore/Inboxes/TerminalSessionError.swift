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

/// Surfaced when the backend's deletion barrier reports this identity as
/// deleted (`identity_deleted` at token mint) outside an in-flight local
/// deletion — typically a paired device discovering the account was
/// deleted from another device.
///
/// Distinct from `DeviceReplacedError`: a revoked installation means
/// "reset locally and re-onboard" (the account lives on), while a deleted
/// account offers only a local wipe — nothing may auto-provision a
/// replacement account without explicit user intent.
public struct AccountDeletedError: TerminalSessionError, Equatable {
    public init() {}
}

public extension Notification.Name {
    /// Posted by the API client when an automatic re-authentication hits
    /// the deletion barrier's terminal response. The session layer maps it
    /// to the `AccountDeletedError` terminal state so a live paired device
    /// lands in a coherent account-deleted surface instead of an endless
    /// stream of auth errors.
    static let accountWasDeletedRemotely: Notification.Name = Notification.Name("convos.session.accountWasDeletedRemotely")
}
