import Foundation

/// Marker for session errors that **cannot** be recovered by
/// retrying `SessionStateMachine`'s authorize path.
///
/// Retryable errors (network hiccup, keychain-daemon stall, XMTP
/// node blip) are the common case — foreground retry pulls the
/// session back to `.ready`. Terminal errors surface the same
/// `SessionStateMachine.State.error` case, but retries silently
/// burn counters and — worse — can flip the state to `.ready` by
/// happenstance (e.g. iCloud Keychain refreshed between retries),
/// masking the UI affordance that was the only real path out.
///
/// `SessionStateMachine.handleRetryFromError` short-circuits when
/// the current error conforms. Observer-side code (banners, reset
/// flows) is the only path out of a terminal state.
///
/// See `docs/plans/icloud-backup-single-inbox.md` §"Terminal errors:
/// `handleRetryFromError` must not retry them".
public protocol TerminalSessionError: Error {}

/// The device's sole XMTP installation has been revoked — either
/// the user restored on another device (Apple ID sync scenario),
/// or an admin action elsewhere. Recovery is a full local reset,
/// not a retry.
public struct DeviceReplacedError: TerminalSessionError, Equatable {
    public init() {}
}
