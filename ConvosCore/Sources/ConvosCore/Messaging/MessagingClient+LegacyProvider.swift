import Foundation

// MARK: - Stage 6e Phase A bridge

public extension MessagingClient {
    /// Stage 6e Phase A bridge: lift this `MessagingClient` back down to
    /// the legacy `XMTPClientProvider` surface for callers that have
    /// not yet migrated. Phase C removes this accessor.
    ///
    /// The default implementation handles two cases that pass tests today:
    /// 1. `XMTPiOSMessagingClient` (the prod XMTPiOS-backed path) — return the
    ///    underlying `XMTPiOS.Client`.
    /// 2. The conformer is *also* an `XMTPClientProvider` directly —
    ///    return `self`. This case exists for the test mocks (e.g.
    ///    `TestableMockClient` in `SyncingManagerTests.swift`) that
    ///    historically conformed to `XMTPClientProvider` and now
    ///    additionally conform to `MessagingClient` for the public
    ///    SyncingManager surface.
    /// Non-XMTPiOS conformers (DTU) deliberately `preconditionFailure`
    /// here; Phase C retires the legacy provider entirely and the DTU
    /// integration tests are unskipped at that point.
    var legacyProvider: any XMTPClientProvider {
        if let xmtpiOS = self as? XMTPiOSMessagingClient {
            return xmtpiOS.xmtpClient
        }
        if let direct = self as? any XMTPClientProvider {
            return direct
        }
        preconditionFailure(
            "MessagingClient.legacyProvider is a Phase A bridge for XMTPiOS-backed clients (or test doubles that double-conform to XMTPClientProvider). Non-XMTPiOS clients should be migrated to the MessagingClient surface in Phase B/C."
        )
    }

    /// Stage 6e Phase A compatibility shim: pre-flip, callers reached
    /// for `inboxReady.client.messagingClient` to lift the legacy
    /// `XMTPClientProvider` into a `MessagingClient`. Post-flip,
    /// `inboxReady.client` already IS a `MessagingClient`; this
    /// accessor returns `self` so the existing call sites keep
    /// compiling without churn. Phase B removes both this shim and
    /// the call sites that route through it.
    var messagingClient: any MessagingClient { self }

    /// Stage 6e Phase A: routes the legacy `messagingConversation(with:)`
    /// helper (previously defined on `XMTPClientProvider` in
    /// `XMTPiOSConversationAdapter.swift`) through the abstraction's
    /// `conversations.find(conversationId:)` so that callers holding
    /// `inboxReady.client` as `any MessagingClient` keep compiling.
    /// Backend-agnostic — XMTPiOS and DTU both back `find`.
    func messagingConversation(
        with conversationId: String
    ) async throws -> MessagingConversation? {
        try await conversations.find(conversationId: conversationId)
    }

    /// Stage 6e Phase A: convenience for callers that need the
    /// `MessagingGroup` subtype directly. Returns `nil` for DMs.
    /// Mirrors the legacy `XMTPClientProvider.messagingGroup(with:)`.
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
