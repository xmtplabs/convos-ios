import Foundation
// FIXME(stage6e): `@preconcurrency import XMTPiOS` remains because this
// factory still exposes `ClientOptions.Api` for legacy static-op
// callers (`SleepingInboxMessageChecker`) and accepts the legacy
// `[any XMTPiOS.ContentCodec]` codec list. Stage 6e Phase A flipped
// `createClient` / `buildClient` return types to `any MessagingClient`
// (Stage 5/6a abstraction surface). The codec list and the
// `apiOptions(_:)` static-op return type still live on the XMTPiOS
// side until Stage 6's codec migration / static-op retirement.
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
/// Stage 4f migrated the signer input to `any MessagingSigner` and
/// the identity to `MessagingIdentity`. Stage 6e Phase A flipped the
/// return type to `any MessagingClient`; the factory now hands back
/// the abstraction-layer handle directly. Adapters wrap the native
/// `XMTPiOS.Client` in `XMTPiOSMessagingClient` (or a DTU-backed
/// equivalent) before returning.
///
/// Custom codecs are still passed separately as native XMTPiOS codec
/// instances. They live on the XMTPiOS side until Stage 6 rewrites
/// them against `MessagingCodec`; passing them through this factory
/// keeps `InboxStateMachine` unaware of the `ClientOptions` shape.
public protocol MessagingClientFactory: Sendable {
    /// Creates a brand-new client using the provided signer.
    ///
    /// Mirrors `XMTPiOS.Client.create(account:options:)`.
    func createClient(
        signer: any MessagingSigner,
        config: MessagingClientConfig,
        xmtpCodecs: [any ContentCodec]
    ) async throws -> any MessagingClient

    /// Rehydrates an existing client from local storage.
    ///
    /// Mirrors `XMTPiOS.Client.build(publicIdentity:options:inboxId:)`.
    func buildClient(
        inboxId: String,
        identity: MessagingIdentity,
        config: MessagingClientConfig,
        xmtpCodecs: [any ContentCodec]
    ) async throws -> any MessagingClient

    /// Produces the adapter-native API options for this config.
    ///
    /// Required for static operations that do not yet go through the
    /// abstraction (e.g. `SleepingInboxMessageChecker` calling
    /// `Client.getNewestMessageMetadata`). The adapter is free to write
    /// adapter-local globals (e.g. `XMTPEnvironment.customLocalAddress`)
    /// here, but the call site does not observe it.
    func apiOptions(config: MessagingClientConfig) -> ClientOptions.Api
}
