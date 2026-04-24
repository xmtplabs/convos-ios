import Foundation
@preconcurrency import XMTPiOS

/// XMTPiOS-backed implementation of `MessagingClient`.
///
/// Composes the four sub-surface adapters (`conversations`, `consent`,
/// `deviceSync`, `installations`) around a single `XMTPiOS.Client`
/// handle. Every method forwards onto the native SDK and maps the
/// return type through the mappers in `XMTPiOSValueMappers.swift`.
///
/// Construction goes through `create(signer:config:)` /
/// `build(identity:inboxId:config:)`. Because `MessagingClientConfig.codecs`
/// is typed as `[any MessagingCodec]` (the Convos-owned protocol), the
/// adapter-local factory path is expected to be driven by the existing
/// `XMTPiOSMessagingClientFactory` which takes a second XMTPiOS-native
/// codec list (`[any ContentCodec]`). The static `create` / `build`
/// methods on this type register the default Convos codec list
/// (`InboxStateMachine.defaultXMTPCodecs`) — see Stage 6 in the audit
/// for when `MessagingCodec` becomes the single codec surface.
public final class XMTPiOSMessagingClient: MessagingClient, @unchecked Sendable {
    /// The underlying native client handle. Kept `internal` so other
    /// adapter-local types can reach it; `private` would prevent the
    /// sub-surface adapters from composing without a property-forward
    /// layer per method.
    let xmtpClient: XMTPiOS.Client

    public let conversations: any MessagingConversations
    public let consent: any MessagingConsent
    public let deviceSync: any MessagingDeviceSync
    public let installations: any MessagingInstallationsAPI

    public init(xmtpClient: XMTPiOS.Client) {
        self.xmtpClient = xmtpClient
        self.conversations = XMTPiOSMessagingConversations(
            xmtpConversations: xmtpClient.conversations
        )
        self.consent = XMTPiOSMessagingConsent(xmtpPreferences: xmtpClient.preferences)
        self.deviceSync = XMTPiOSMessagingDeviceSync(xmtpClient: xmtpClient)
        self.installations = XMTPiOSMessagingInstallationsAPI(xmtpClient: xmtpClient)
    }

    // MARK: - Identity accessors

    public var inboxId: MessagingInboxID { xmtpClient.inboxID }
    public var installationId: MessagingInstallationID { xmtpClient.installationID }
    public var publicIdentity: MessagingIdentity {
        MessagingIdentity(xmtpClient.publicIdentity)
    }

    // MARK: - Construction

    public static func create(
        signer: any MessagingSigner,
        config: MessagingClientConfig
    ) async throws -> Self {
        let xmtpProvider = try await XMTPiOSMessagingClientFactory.shared.createClient(
            signingKey: XMTPiOSSigningKeyAdapter(signer),
            config: config,
            xmtpCodecs: Self.defaultXMTPCodecs()
        )
        guard let xmtpClient = xmtpProvider as? XMTPiOS.Client else {
            throw XMTPiOSMessagingClientError.unexpectedProviderType
        }
        // swiftlint:disable:next force_cast
        return Self(xmtpClient: xmtpClient) as! Self
    }

    public static func build(
        identity: MessagingIdentity,
        inboxId: MessagingInboxID?,
        config: MessagingClientConfig
    ) async throws -> Self {
        // The factory's `buildClient` requires a non-optional inboxId
        // and delegates to `XMTPiOS.Client.build(publicIdentity:options:inboxId:)`.
        // If the caller did not hand us one, we fall back to
        // `Client.build` directly — it will resolve the inbox via
        // `getOrCreateInboxId` under the hood.
        if let inboxId {
            let xmtpProvider = try await XMTPiOSMessagingClientFactory.shared.buildClient(
                inboxId: inboxId,
                identity: identity.xmtpPublicIdentity,
                config: config,
                xmtpCodecs: Self.defaultXMTPCodecs()
            )
            guard let xmtpClient = xmtpProvider as? XMTPiOS.Client else {
                throw XMTPiOSMessagingClientError.unexpectedProviderType
            }
            // swiftlint:disable:next force_cast
            return Self(xmtpClient: xmtpClient) as! Self
        } else {
            // Direct SDK fallback for the no-inbox-id flow (getOrCreateInboxId).
            let options = try await Self.clientOptions(for: config)
            let xmtpClient = try await XMTPiOS.Client.build(
                publicIdentity: identity.xmtpPublicIdentity,
                options: options,
                inboxId: nil
            )
            // swiftlint:disable:next force_cast
            return Self(xmtpClient: xmtpClient) as! Self
        }
    }

    // MARK: - Static ops

    public static func newestMessageMetadata(
        conversationIds: [String],
        config: MessagingClientConfig
    ) async throws -> [String: MessagingMessageMetadata] {
        // Respect the per-instance config's custom local address.
        let apiOptions = XMTPiOSMessagingClientFactory.shared.apiOptions(config: config)
        let raw = try await XMTPiOS.Client.getNewestMessageMetadata(
            groupIds: conversationIds,
            api: apiOptions
        )
        // FIXME(upstream): `FfiMessageMetadata` does not yet surface a
        // sender identity. Until libxmtp adds it, we synthesize empty
        // senderInboxId for each returned entry — only the `sentAtNs`
        // field is load-bearing for SleepingInboxMessageChecker today.
        return raw.mapValues { xmtpMeta in
            MessagingMessageMetadata(xmtpMeta, senderInboxId: "")
        }
    }

    public static func canMessage(
        identities: [MessagingIdentity],
        config: MessagingClientConfig
    ) async throws -> [String: Bool] {
        let apiOptions = XMTPiOSMessagingClientFactory.shared.apiOptions(config: config)
        return try await XMTPiOS.Client.canMessage(
            accountIdentities: identities.map(\.xmtpPublicIdentity),
            api: apiOptions
        )
    }

    // MARK: - Per-instance reachability

    public func canMessage(identity: MessagingIdentity) async throws -> Bool {
        try await xmtpClient.canMessage(identity: identity.xmtpPublicIdentity)
    }

    public func canMessage(identities: [MessagingIdentity]) async throws -> [String: Bool] {
        try await xmtpClient.canMessage(identities: identities.map(\.xmtpPublicIdentity))
    }

    public func inboxId(for identity: MessagingIdentity) async throws -> MessagingInboxID? {
        try await xmtpClient.inboxIdFromIdentity(identity: identity.xmtpPublicIdentity)
    }

    // MARK: - Signing / verification

    public func signWithInstallationKey(_ message: String) throws -> Data {
        try xmtpClient.signWithInstallationKey(message: message)
    }

    public func verifySignature(_ message: String, signature: Data) throws -> Bool {
        try xmtpClient.verifySignature(message: message, signature: signature)
    }

    public func verifySignature(
        _ message: String,
        signature: Data,
        installationId: MessagingInstallationID
    ) throws -> Bool {
        try xmtpClient.verifySignatureWithInstallationId(
            message: message,
            signature: signature,
            installationId: installationId
        )
    }

    // MARK: - DB lifecycle

    public func deleteLocalDatabase() throws {
        try xmtpClient.deleteLocalDatabase()
    }

    public func reconnectLocalDatabase() async throws {
        try await xmtpClient.reconnectLocalDatabase()
    }

    public func dropLocalDatabaseConnection() throws {
        try xmtpClient.dropLocalDatabaseConnection()
    }

    // MARK: - Private helpers

    private static func defaultXMTPCodecs() -> [any ContentCodec] {
        InboxStateMachine.defaultXMTPCodecs()
    }

    /// Build `ClientOptions` purely for the static-build fallback path
    /// when the factory helper cannot be used (no explicit inbox id).
    /// Mirrors the factory's translation so the adapter stays the
    /// single code path that constructs `ClientOptions`.
    private static func clientOptions(
        for config: MessagingClientConfig
    ) async throws -> XMTPiOS.ClientOptions {
        let api = XMTPiOSMessagingClientFactory.shared.apiOptions(config: config)
        return ClientOptions(
            api: api,
            codecs: Self.defaultXMTPCodecs(),
            dbEncryptionKey: config.dbEncryptionKey,
            dbDirectory: config.dbDirectory,
            deviceSyncEnabled: config.deviceSyncEnabled,
            maxDbPoolSize: 10,
            minDbPoolSize: 3
        )
    }
}

// MARK: - Errors

public enum XMTPiOSMessagingClientError: Error, LocalizedError {
    case unexpectedProviderType

    public var errorDescription: String? {
        switch self {
        case .unexpectedProviderType:
            return "XMTPiOSMessagingClient: factory returned a non-XMTPiOS provider"
        }
    }
}
