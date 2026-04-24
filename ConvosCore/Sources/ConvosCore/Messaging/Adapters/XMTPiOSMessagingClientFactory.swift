import Foundation
@preconcurrency import XMTPiOS

/// XMTPiOS-backed implementation of `MessagingClientFactory`.
///
/// This is the Stage 5 boundary file for client construction. Every
/// `Client.create` / `Client.build` call, every construction of
/// `ClientOptions`, and every write to the global mutable
/// `XMTPEnvironment.customLocalAddress` live behind this single type.
///
/// Callers (`InboxStateMachine`, `XMTPAPIOptionsBuilder`) pass a
/// per-instance `MessagingClientConfig`; they do not read or write
/// process-wide XMTPiOS state themselves. That boundary is what the
/// audit §2 flags as the DTU hazard — having it guarded by one file
/// makes the eventual DTU adapter a drop-in replacement.
public struct XMTPiOSMessagingClientFactory: MessagingClientFactory {
    public static let shared: XMTPiOSMessagingClientFactory = XMTPiOSMessagingClientFactory()

    public init() {}

    public func createClient(
        signer: any MessagingSigner,
        config: MessagingClientConfig,
        xmtpCodecs: [any ContentCodec]
    ) async throws -> any XMTPClientProvider {
        applyLocalAddressOverride(config: config)
        let options = clientOptions(config: config, xmtpCodecs: xmtpCodecs)
        Log.info("Creating XMTP client...")
        // Wrap the Convos-owned signer so `XMTPiOS.Client.create` gets the
        // native `SigningKey` protocol it expects. This is the only
        // boundary where the forward adapter is used.
        let signingKey = XMTPiOSSigningKeyAdapter(signer)
        let client = try await Client.create(account: signingKey, options: options)
        Log.info("XMTP Client created with app version: convos/\(Bundle.appVersion)")
        return client
    }

    public func buildClient(
        inboxId: String,
        identity: MessagingIdentity,
        config: MessagingClientConfig,
        xmtpCodecs: [any ContentCodec]
    ) async throws -> any XMTPClientProvider {
        applyLocalAddressOverride(config: config)
        let options = clientOptions(config: config, xmtpCodecs: xmtpCodecs)
        Log.debug("Building XMTP client for \(inboxId)...")
        let client = try await Client.build(
            publicIdentity: identity.xmtpPublicIdentity,
            options: options,
            inboxId: inboxId
        )
        Log.debug("XMTP Client built.")
        return client
    }

    public func apiOptions(config: MessagingClientConfig) -> ClientOptions.Api {
        applyLocalAddressOverride(config: config)
        return ClientOptions.Api(
            env: config.apiEnv.xmtpEnv,
            isSecure: config.isSecure,
            appVersion: config.appVersion ?? "convos/\(Bundle.appVersion)"
        )
    }

    // MARK: - Private helpers

    /// The only place in the codebase that writes the global mutable
    /// `XMTPEnvironment.customLocalAddress`. It is driven entirely by
    /// the per-instance config passed in.
    ///
    /// Longer term, once libxmtp exposes an `apiUrl` on `ClientOptions.Api`
    /// or via the gateway flow, this call becomes a no-op and we delete
    /// the global. Until then, keeping the write here is correct:
    /// callers hand in `config.customLocalAddress` and don't observe the
    /// side effect.
    private func applyLocalAddressOverride(config: MessagingClientConfig) {
        if let customHost = config.customLocalAddress {
            Log.debug("Setting XMTPEnvironment.customLocalAddress = \(customHost)")
            XMTPEnvironment.customLocalAddress = customHost
        } else {
            Log.debug("Clearing XMTPEnvironment.customLocalAddress")
            XMTPEnvironment.customLocalAddress = nil
        }
    }

    private func clientOptions(
        config: MessagingClientConfig,
        xmtpCodecs: [any ContentCodec]
    ) -> ClientOptions {
        let apiOptions = ClientOptions.Api(
            env: config.apiEnv.xmtpEnv,
            isSecure: config.isSecure,
            appVersion: config.appVersion ?? "convos/\(Bundle.appVersion)"
        )
        return ClientOptions(
            api: apiOptions,
            codecs: xmtpCodecs,
            dbEncryptionKey: config.dbEncryptionKey,
            dbDirectory: config.dbDirectory,
            deviceSyncEnabled: config.deviceSyncEnabled,
            maxDbPoolSize: 10,
            minDbPoolSize: 3
        )
    }
}

// MARK: - MessagingEnv <-> XMTPiOS.XMTPEnvironment

extension MessagingEnv {
    /// Adapter-side translation from the Convos-owned env enum to the
    /// native XMTPiOS one. Defined in the adapter file so that non-
    /// adapter code never constructs `XMTPEnvironment` directly.
    var xmtpEnv: XMTPEnvironment {
        switch self {
        case .local: return .local
        case .dev: return .dev
        case .production: return .production
        }
    }
}

// MARK: - AppEnvironment -> MessagingClientConfig builder

public extension AppEnvironment {
    /// Builds a per-instance `MessagingClientConfig` from this
    /// `AppEnvironment`. Every client-construction site goes through
    /// this so the global `XMTPEnvironment.customLocalAddress` is no
    /// longer read at the call site.
    func messagingClientConfig(
        dbEncryptionKey: Data,
        dbDirectory: String? = nil,
        appVersion: String? = nil,
        deviceSyncEnabled: Bool = false,
        codecs: [any MessagingCodec] = []
    ) -> MessagingClientConfig {
        MessagingClientConfig(
            apiEnv: self.messagingEnv,
            customLocalAddress: self.customLocalAddress,
            isSecure: self.isSecure,
            appVersion: appVersion ?? "convos/\(Bundle.appVersion)",
            dbEncryptionKey: dbEncryptionKey,
            dbDirectory: dbDirectory ?? self.defaultDatabasesDirectory,
            deviceSyncEnabled: deviceSyncEnabled,
            codecs: codecs
        )
    }

    /// Adapter-local mapping from `AppEnvironment` to the abstraction's
    /// `MessagingEnv`. Mirrors `AppEnvironment.xmtpEnv` from
    /// `XMTPAPIOptionsBuilder.swift` but lands on the Convos-owned enum
    /// so that non-adapter code can reason about it.
    var messagingEnv: MessagingEnv {
        switch self.xmtpEnv {
        case .local: return .local
        case .dev: return .dev
        case .production: return .production
        }
    }
}
