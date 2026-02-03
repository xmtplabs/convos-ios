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
    public let databaseDirectoryURL: URL?
    public let skipBackendAuth: Bool
    public let keychainAccessGroup: String?
    public let useLocalKeychain: Bool

    public init(
        apiBaseURL: String,
        appGroupIdentifier: String,
        relyingPartyIdentifier: String,
        xmtpEndpoint: String? = nil,
        xmtpNetwork: String? = nil,
        gatewayUrl: String? = nil,
        databaseDirectoryURL: URL? = nil,
        skipBackendAuth: Bool = false,
        keychainAccessGroup: String? = nil,
        useLocalKeychain: Bool = false
    ) {
        self.apiBaseURL = apiBaseURL
        self.appGroupIdentifier = appGroupIdentifier
        self.relyingPartyIdentifier = relyingPartyIdentifier
        self.xmtpEndpoint = xmtpEndpoint
        self.xmtpNetwork = xmtpNetwork
        self.gatewayUrl = gatewayUrl
        self.databaseDirectoryURL = databaseDirectoryURL
        self.skipBackendAuth = skipBackendAuth
        self.keychainAccessGroup = keychainAccessGroup
        self.useLocalKeychain = useLocalKeychain
    }
}
