import Foundation
@preconcurrency import XMTPiOS

/// Factory surface for building an XMTP-backed client from a
/// per-instance `MessagingClientConfig`.
///
/// This replaces the direct `XMTPiOS.Client.create` / `Client.build`
/// calls previously made inside `InboxStateMachine` (audit §5 Stage 5,
/// lines `InboxStateMachine.swift:1140-1156`), and localizes the
/// `XMTPEnvironment.customLocalAddress` write so that one single
/// adapter file owns it (audit §2: global mutable state hazard).
///
/// Callers pass a per-instance `MessagingClientConfig` — no process-
/// wide state is read or written by the call site.
///
/// We keep the factory signatures expressed in the existing XMTPiOS
/// `SigningKey` / `PublicIdentity` types for now. Those types are a
/// later-stage migration target (Stage 4 in the audit) and rewriting
/// them here would widen scope well beyond Stage 5. The important
/// invariant is that the only module touching `Client.create`,
/// `Client.build`, `ClientOptions`, and `XMTPEnvironment.customLocalAddress`
/// is the adapter conforming to this protocol.
///
/// Custom codecs are passed separately as native XMTPiOS codec
/// instances. They live on the XMTPiOS side until Stage 3 rewrites
/// them against `MessagingCodec`; passing them through this factory
/// keeps `InboxStateMachine` unaware of the `ClientOptions` shape.
public protocol MessagingClientFactory: Sendable {
    /// Creates a brand-new client using the provided signer.
    ///
    /// Mirrors `XMTPiOS.Client.create(account:options:)`.
    func createClient(
        signingKey: any SigningKey,
        config: MessagingClientConfig,
        xmtpCodecs: [any ContentCodec]
    ) async throws -> any XMTPClientProvider

    /// Rehydrates an existing client from local storage.
    ///
    /// Mirrors `XMTPiOS.Client.build(publicIdentity:options:inboxId:)`.
    func buildClient(
        inboxId: String,
        identity: PublicIdentity,
        config: MessagingClientConfig,
        xmtpCodecs: [any ContentCodec]
    ) async throws -> any XMTPClientProvider

    /// Produces the adapter-native API options for this config.
    ///
    /// Required for static operations that do not yet go through the
    /// abstraction (e.g. `SleepingInboxMessageChecker` calling
    /// `Client.getNewestMessageMetadata`). The adapter is free to write
    /// adapter-local globals (e.g. `XMTPEnvironment.customLocalAddress`)
    /// here, but the call site does not observe it.
    func apiOptions(config: MessagingClientConfig) -> ClientOptions.Api
}
