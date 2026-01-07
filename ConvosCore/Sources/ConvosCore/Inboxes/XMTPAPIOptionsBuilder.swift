import Foundation
import XMTPiOS

/// Builds XMTP API options for the given environment
///
/// This extracts the API options construction from InboxStateMachine for reuse
/// in static XMTP operations like `getNewestMessageMetadata`.
public struct XMTPAPIOptionsBuilder {
    /// Builds ClientOptions.Api for the given environment
    ///
    /// - Parameter environment: The app environment to build options for
    /// - Returns: Configured API options for XMTP client
    public static func build(environment: AppEnvironment) -> ClientOptions.Api {
        // Set custom local address if configured
        if let customHost = environment.customLocalAddress {
            Log.debug("Setting XMTPEnvironment.customLocalAddress = \(customHost)")
            XMTPEnvironment.customLocalAddress = customHost
        } else {
            XMTPEnvironment.customLocalAddress = nil
        }

        return ClientOptions.Api(
            env: environment.xmtpEnv,
            isSecure: environment.isSecure,
            appVersion: "convos/\(Bundle.appVersion)"
        )
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
