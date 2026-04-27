import ConvosMessagingProtocols
import Foundation
// FIXME: `@preconcurrency import XMTPiOS` remains because this factory
// still exposes `ClientOptions.Api` for static-op callers
// (`SleepingInboxMessageChecker`) and accepts a
// `[any XMTPiOS.ContentCodec]` codec list. The codec list and the
// `apiOptions(_:)` static-op return type still live on the XMTPiOS
// side until codecs migrate onto `MessagingCodec` and the static-op
// path retires.
@preconcurrency import XMTPiOS

/// Factory surface for building a `MessagingClient` from a per-instance
/// `MessagingClientConfig`.
///
/// Localizes the `XMTPEnvironment.customLocalAddress` write so a single
/// adapter file owns the global mutable state hazard. Callers pass a
/// per-instance config and never read or write process-wide state
/// themselves; signer is `any MessagingSigner`, identity is
/// `MessagingIdentity`.
///
/// Custom codecs are passed separately as native XMTPiOS codec instances
/// because the codecs still live in the XMTPiOS layer; passing them
/// through this factory keeps `InboxStateMachine` unaware of the
/// `ClientOptions` shape.
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
