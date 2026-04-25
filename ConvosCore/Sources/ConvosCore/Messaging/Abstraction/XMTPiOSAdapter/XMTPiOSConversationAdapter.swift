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

// MARK: - Stage 4 bridge

public extension MessagingConversation {
    // Stage 4 bridge — remove when Stage 3 writers migrate.
    // Stage 4 callers hold a `MessagingConversation` enum but must hand
    // the raw `XMTPiOS.Conversation` to not-yet-migrated writers.
    // Matches `.group` / `.dm` and rebuilds the native enum. Returns
    // `nil` if the payload is not an XMTPiOS adapter.
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

// MARK: - Stage 3 bridge — XMTPClientProvider → MessagingConversation

public extension XMTPClientProvider {
    /// Convenience that looks up a native XMTPiOS conversation and
    /// wraps it in the abstraction-layer `MessagingConversation`.
    ///
    /// Added for Stage 3 writer migration: writers that used to reach
    /// for `client.conversation(with:)` → `XMTPiOS.Conversation` can
    /// instead call `client.messagingConversation(with:)` and keep
    /// their file free of `import XMTPiOS`. The XMTPiOS → abstraction
    /// wrapping is localized here.
    func messagingConversation(
        with conversationId: String
    ) async throws -> MessagingConversation? {
        guard let xmtpConversation = try await conversation(with: conversationId) else {
            return nil
        }
        return XMTPiOSConversationAdapter.messagingConversation(xmtpConversation)
    }

    /// Convenience for writers that need the `MessagingGroup` subtype
    /// directly. Returns `nil` for DMs.
    func messagingGroup(
        with conversationId: String
    ) async throws -> (any MessagingGroup)? {
        guard let conversation = try await messagingConversation(with: conversationId) else {
            return nil
        }
        if case .group(let group) = conversation {
            return group
        }
        return nil
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
