import Foundation

/// Thrown by `ConvosCoreDTU` adapter methods when the `Messaging*` protocol
/// surface exposes an operation that the DTU engine + SDK do not yet model.
///
/// The DTU engine (see `xmtp-dtu/docs/dtu-server-wire.md`) is a universe
/// simulator focused on the MLS + messaging + membership surface. Several
/// XMTPiOS-specific capabilities — device-sync archives, HMAC keys, push
/// topics, signature verification — either live outside the engine or have
/// not yet been modeled. Methods that fall into that bucket throw this
/// error rather than silently no-op so callers can handle the gap
/// explicitly (e.g. FIXME or test-skip).
///
/// Each case carries the abstraction-level method name that was called plus
/// a human reason. Callers can switch on the method name for targeted
/// handling; otherwise the `description` string is safe to surface in test
/// output or a Sentry breadcrumb.
public struct DTUMessagingNotSupportedError: Error, CustomStringConvertible, Sendable {
    public let method: String
    public let reason: String

    public init(method: String, reason: String) {
        self.method = method
        self.reason = reason
    }

    public var description: String {
        "DTUMessagingNotSupportedError(\(method)): \(reason)"
    }
}

extension DTUMessagingNotSupportedError: LocalizedError {
    public var errorDescription: String? { description }
}

// MARK: - Internal state errors

/// Internal errors raised by the adapter's own bookkeeping — distinct from
/// `DTUMessagingNotSupportedError`, which covers protocol methods that map
/// onto engine gaps. These fire when the adapter's local cache / handle
/// registry is in an inconsistent state (e.g. a conversation alias the
/// abstraction is asked to operate on is unknown to the adapter).
public enum DTUMessagingAdapterError: Error, LocalizedError, Sendable {
    case unknownConversationAlias(String)
    case unknownMessageAlias(String)
    case unexpectedMessageContent(alias: String, reason: String)

    public var errorDescription: String? {
        switch self {
        case .unknownConversationAlias(let alias):
            return "DTU adapter: unknown conversation alias \"\(alias)\""
        case .unknownMessageAlias(let alias):
            return "DTU adapter: unknown message alias \"\(alias)\""
        case .unexpectedMessageContent(let alias, let reason):
            return "DTU adapter: cannot decode message \"\(alias)\": \(reason)"
        }
    }
}
