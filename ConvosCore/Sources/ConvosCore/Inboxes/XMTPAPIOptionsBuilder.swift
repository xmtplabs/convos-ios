import ConvosMessagingProtocols
import Foundation
// FIXME: see docs/outstanding-messaging-abstraction-work.md#factory-clientoptions-api
@preconcurrency import XMTPiOS

/// Builds XMTP API options for the given environment.
///
/// The actual `XMTPEnvironment.customLocalAddress` write is delegated
/// to the `MessagingClientFactory` adapter so that the global mutable
/// state lives behind a single boundary file. Callers here pass an
/// `AppEnvironment` and stay unaware of the XMTP global.
public struct XMTPAPIOptionsBuilder {
    /// Builds ClientOptions.Api for the given environment
    ///
    /// - Parameters:
    ///   - environment: The app environment to build options for
    ///   - factory: The messaging client factory used for translation.
    ///     Defaults to the shared XMTPiOS-backed factory.
    /// - Returns: Configured API options for XMTP client
    public static func build(
        environment: AppEnvironment,
        factory: any MessagingClientFactory = XMTPiOSMessagingClientFactory.shared
    ) -> ClientOptions.Api {
        // Delegate to the factory so the global `XMTPEnvironment.customLocalAddress`
        // write (and `ClientOptions.Api` construction) lives inside the
        // adapter, not here. We synthesize a minimal config carrying
        // only the fields `ClientOptions.Api` actually consumes; the
        // remaining config fields (`dbEncryptionKey`, `codecs`, etc.)
        // are unused on the static-op path.
        let config = MessagingClientConfig(
            apiEnv: environment.messagingEnv,
            customLocalAddress: environment.customLocalAddress,
            isSecure: environment.isSecure,
            appVersion: "convos/\(Bundle.appVersion)",
            dbEncryptionKey: Data(),
            dbDirectory: nil,
            deviceSyncEnabled: false,
            codecs: []
        )
        return factory.apiOptions(config: config)
    }
}

// MARK: - AppEnvironment XMTP Extensions

public extension AppEnvironment {
    /// The XMTP environment to connect to
    var xmtpEnv: XMTPEnvironment {
        if let network = self.xmtpNetwork {
            switch network.lowercased() {
            case "local": return .local
            case "dev": return .dev
            case "production", "prod": return .production
            default:
                Log.warning("Unknown xmtpNetwork '\(network)', falling back to environment default")
            }
        }

        switch self {
        case .local, .tests: return .local
        case .dev: return .dev
        case .production: return .production
        }
    }

    /// Custom local address for XMTP endpoint (if configured)
    var customLocalAddress: String? {
        guard let endpoint = self.xmtpEndpoint, !endpoint.isEmpty else {
            return nil
        }
        return endpoint
    }

    /// Whether to use secure (TLS) connection
    var isSecure: Bool {
        switch self {
        case .local, .tests:
            // Support environment variable for CI
            guard let envSecure = ProcessInfo.processInfo.environment["XMTP_IS_SECURE"] else {
                return false
            }
            return envSecure.lowercased() == "true" || envSecure == "1"
        default:
            return true
        }
    }
}
