import Foundation

/// Per-environment SIWE (Sign-In With Ethereum, EIP-4361) values.
///
/// These fields are echoed into the SIWE message the iOS app signs and
/// must match the backend's `SIWE_DOMAIN`, `SIWE_URI`, and an entry of
/// `SIWE_ALLOWED_CHAIN_IDS` exactly. Mismatch causes 401 Invalid SIWE.
public struct SIWEConfiguration: Codable, Sendable, Equatable {
    public let domain: String
    public let uri: String
    public let chainId: Int

    public init(domain: String, uri: String, chainId: Int) {
        self.domain = domain
        self.uri = uri
        self.chainId = chainId
    }
}

/// Configuration values passed from the host app to ConvosCore
///
/// This is a pure data container - all configuration values must be provided
/// by the host application. The host app is responsible for reading these
/// values from its configuration files (config.json, Secrets, etc.)
///
/// ConvosCore does not have any hardcoded configuration values to ensure
/// that all environments are properly configured through the host app.
public struct ConvosConfiguration: Sendable {
    public let apiBaseURL: String
    public let appGroupIdentifier: String
    public let relyingPartyIdentifier: String
    public let siweConfiguration: SIWEConfiguration
    public let xmtpEndpoint: String?
    public let xmtpNetwork: String?
    public let gatewayUrl: String?

    public init(
        apiBaseURL: String,
        appGroupIdentifier: String,
        relyingPartyIdentifier: String,
        siweConfiguration: SIWEConfiguration,
        xmtpEndpoint: String? = nil,
        xmtpNetwork: String? = nil,
        gatewayUrl: String? = nil
    ) {
        self.apiBaseURL = apiBaseURL
        self.appGroupIdentifier = appGroupIdentifier
        self.relyingPartyIdentifier = relyingPartyIdentifier
        self.siweConfiguration = siweConfiguration
        self.xmtpEndpoint = xmtpEndpoint
        self.xmtpNetwork = xmtpNetwork
        self.gatewayUrl = gatewayUrl
    }
}
