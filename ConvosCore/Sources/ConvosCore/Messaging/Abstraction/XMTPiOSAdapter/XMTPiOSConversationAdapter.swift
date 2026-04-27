import ConvosMessagingProtocols
import Foundation
@preconcurrency import XMTPiOS

/// Maps a native `XMTPiOS.Conversation` enum value onto the Convos-
/// owned `MessagingConversation` enum. Preserves the `.group(...)` /
/// `.dm(...)` shape that the audit flags as load-bearing — Convos
/// pattern-matches on both cases in `StreamProcessor.swift:187` and
/// throughout sync.
enum XMTPiOSConversationAdapter {
    /// Convert an XMTPiOS native conversation to the abstraction-level
    /// enum. The adapter instance for each case caches the underlying
    /// SDK handle so subsequent method calls forward directly onto it.
    static func messagingConversation(
        _ xmtpConversation: XMTPiOS.Conversation
    ) -> MessagingConversation {
        switch xmtpConversation {
        case .group(let group):
            return .group(XMTPiOSMessagingGroup(xmtpGroup: group))
        case .dm(let dm):
            return .dm(XMTPiOSMessagingDm(xmtpDm: dm))
        }
    }
}

// MARK: - Native handle escape hatch

public extension MessagingConversation {
    // Escape hatch for call sites that need to hand the raw
    // `XMTPiOS.Conversation` to XMTPiOS-typed surfaces (codecs, the
    // notification chain). Returns `nil` if the payload is not an
    // XMTPiOS adapter.
    var underlyingXMTPiOSConversation: XMTPiOS.Conversation? {
        switch self {
        case .group(let group):
            guard let wrapped = group as? XMTPiOSMessagingGroup else { return nil }
            return .group(wrapped.underlyingXMTPiOSGroup)
        case .dm(let dm):
            guard let wrapped = dm as? XMTPiOSMessagingDm else { return nil }
            return .dm(wrapped.underlyingXMTPiOSDm)
        }
    }
}

// MARK: - Errors

enum XMTPiOSAdapterError: Error, LocalizedError {
    case messageDecodeFailed
    case processMessageFailed

    var errorDescription: String? {
        switch self {
        case .messageDecodeFailed: return "Failed to decode incoming XMTPiOS message"
        case .processMessageFailed: return "Failed to process raw push bytes"
        }
    }
}
