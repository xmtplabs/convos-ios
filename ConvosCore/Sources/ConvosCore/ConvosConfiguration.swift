import Foundation

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
    public let xmtpEndpoint: String?
    public let xmtpNetwork: String?
    public let gatewayUrl: String?
    public let allowedAssetHosts: [String]

    public init(
        apiBaseURL: String,
        appGroupIdentifier: String,
        relyingPartyIdentifier: String,
        xmtpEndpoint: String? = nil,
        xmtpNetwork: String? = nil,
        gatewayUrl: String? = nil,
        allowedAssetHosts: [String] = []
    ) {
        self.apiBaseURL = apiBaseURL
        self.appGroupIdentifier = appGroupIdentifier
        self.relyingPartyIdentifier = relyingPartyIdentifier
        self.xmtpEndpoint = xmtpEndpoint
        self.xmtpNetwork = xmtpNetwork
        self.gatewayUrl = gatewayUrl
        self.allowedAssetHosts = allowedAssetHosts
    }
}
