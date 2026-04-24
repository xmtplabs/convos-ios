import Foundation

/// APNS environment for push notifications
public enum ApnsEnvironment: String, Codable {
    case sandbox
    case production
}

/// Build environment based on provisioning and target
public enum BuildEnvironment {
    case simulator
    case development
    case distribution
}

/// Application environment configuration
///
/// Defines the runtime environment (local, dev, production, tests) and provides
/// environment-specific configuration including API URLs, database paths, XMTP endpoints,
/// and keychain/app group settings. The environment determines build behavior, logging,
/// and service configuration throughout the app.
public enum AppEnvironment: Sendable {
    case local(config: ConvosConfiguration)
    case tests
    case dev(config: ConvosConfiguration)
    case production(config: ConvosConfiguration)

    // Only used for testing
    public var defaultOverrideJWTToken: String? {
        switch self {
        case .tests:
            return "test-override-jwt-token"
        default:
            return nil
        }
    }

    public var name: String {
        switch self {
        case .local:
            return "local"
        case .dev:
            return "dev"
        case .production:
            return "production"
        case .tests:
            return "tests"
        }
    }

    /// Create an environment with custom configuration
    public static func configured(_ config: ConvosConfiguration, type: EnvironmentType) -> AppEnvironment {
        switch type {
        case .local:
            return .local(config: config)
        case .dev:
            return .dev(config: config)
        case .production:
            return .production(config: config)
        case .tests:
            return .tests
        }
    }

    public enum EnvironmentType {
        case local, dev, production, tests
    }

    public var firebaseConfigURL: URL? {
        let resource: String
        switch self {
        case .local, .tests:
            resource = "GoogleService-Info.Local"
        case .dev:
            resource = "GoogleService-Info.Dev"
        case .production:
            resource = "GoogleService-Info.Prod"
        }

        if let url = Bundle.main.url(forResource: resource, withExtension: "plist") {
            return url
        }

        return nil
    }

    var apiBaseURL: String {
        switch self {
        case .local(let config):
            Log.info("Using API URL from local config: \(config.apiBaseURL)")
            return config.apiBaseURL
        case .tests:
            return "http://localhost:4000/api"
        case .dev(let config):
            Log.info("Using API URL from dev config: \(config.apiBaseURL)")
            return config.apiBaseURL
        case .production(let config):
            Log.info("Using API URL from production config: \(config.apiBaseURL)")
            return config.apiBaseURL
        }
    }

    public var appGroupIdentifier: String {
        switch self {
        case .local(config: let config), .dev(config: let config), .production(config: let config):
            return config.appGroupIdentifier
        case .tests:
            return "group.org.convos.ios-local"
        }
    }

    public var keychainAccessGroup: String {
        // Use the app group identifier with team prefix for keychain sharing
        // This matches $(AppIdentifierPrefix)$(APP_GROUP_IDENTIFIER) in entitlements
        let teamPrefix = "FY4NZR34Z3."
        return teamPrefix + appGroupIdentifier
    }

    public var relyingPartyIdentifier: String {
        switch self {
        case .local(config: let config), .dev(config: let config), .production(config: let config):
            return config.relyingPartyIdentifier
        case .tests:
            return "local.convos.org"
        }
    }

    var xmtpEndpoint: String? {
        switch self {
        case .local(config: let config), .dev(config: let config), .production(config: let config):
            return config.xmtpEndpoint
        case .tests:
            // Support environment variable for CI
            // Falls back to localhost for local Docker
            if let envEndpoint = ProcessInfo.processInfo.environment["XMTP_NODE_ADDRESS"] {
                return envEndpoint
            }
            return "localhost"
        }
    }

    var xmtpNetwork: String? {
        switch self {
        case .local(config: let config), .dev(config: let config), .production(config: let config):
            return config.xmtpNetwork
        case .tests:
            return nil
        }
    }

    var gatewayUrl: String? {
        switch self {
        case .local(config: let config), .dev(config: let config), .production(config: let config):
            return config.gatewayUrl
        case .tests:
            return nil
        }
    }

    public var apnsEnvironment: ApnsEnvironment {
        switch buildEnvironment {
        case .simulator:
            Log.info("Simulator build detected - using sandbox APNS")
            return .sandbox
        case .development:
            Log.info("Development build detected (has embedded.mobileprovision) - using sandbox APNS")
            return .sandbox
        case .distribution:
            Log.info("Distribution build detected (TestFlight/App Store) - using production APNS")
            return .production
        }
    }

    public var buildEnvironment: BuildEnvironment {
        if isSimulator() {
            return .simulator
        } else if hasEmbeddedMobileProvision() {
            return .development
        } else {
            return .distribution
        }
    }

    public func isSimulator() -> Bool {
        #if targetEnvironment(simulator)
        return true
        #else
        return false
        #endif
    }

    public func hasEmbeddedMobileProvision() -> Bool {
        Bundle.main.path(forResource: "embedded", ofType: "mobileprovision") != nil
    }
}

public extension AppEnvironment {
    var isTestingEnvironment: Bool {
        switch self {
        case .tests:
            true
        default:
            false
        }
    }

    var isProduction: Bool {
        switch self {
        case .production:
            true
        default:
            false
        }
    }

    var defaultXMTPLogsDirectoryURL: URL {
        guard !isTestingEnvironment else {
            return FileManager.default.temporaryDirectory
        }

        guard let groupUrl = FileManager.default.containerURL(
            forSecurityApplicationGroupIdentifier: appGroupIdentifier
        ) else {
            fatalError("Failed getting container URL for group identifier: \(appGroupIdentifier)")
        }
        return groupUrl.appendingPathComponent("logs", isDirectory: true)
    }

    var defaultDatabasesDirectoryURL: URL {
        guard !isTestingEnvironment else {
            return FileManager.default.temporaryDirectory
        }

        guard let groupUrl = FileManager.default.containerURL(
            forSecurityApplicationGroupIdentifier: appGroupIdentifier
        ) else {
            fatalError("Failed getting container URL for group identifier: \(appGroupIdentifier)")
        }
        return groupUrl
    }

    var defaultDatabasesDirectory: String {
        defaultDatabasesDirectoryURL.path
    }

    /// Root directory under the app-group container reserved for backup/restore
    /// bookkeeping (rollback artifacts, staged bundles). Kept inside the shared
    /// container so the NSE can observe in-flight transactions and so crash
    /// recovery on next launch can inspect them.
    var backupBookkeepingDirectoryURL: URL {
        defaultDatabasesDirectoryURL.appendingPathComponent("backup", isDirectory: true)
    }

    /// iCloud container identifier used for backup bundle persistence.
    ///
    /// Matches the entitlement's `$(ICLOUD_CONTAINER_IDENTIFIER)` build
    /// variable (`iCloud.<bundleId>`). Returns `nil` in the testing
    /// environment because SPM tests have no `Bundle.main.bundleIdentifier`
    /// and no iCloud entitlement. At runtime, `BackupManager` falls back
    /// to the local app-group directory when this resolves to `nil` or
    /// when the container isn't reachable (user signed out of iCloud,
    /// entitlement not yet provisioned in Apple Developer for the
    /// active bundle id, etc).
    var iCloudContainerIdentifier: String? {
        guard !isTestingEnvironment,
              let bundleId = Bundle.main.bundleIdentifier,
              !bundleId.isEmpty else {
            return nil
        }
        return "iCloud.\(bundleId)"
    }

    /// App marketing version read from the host bundle. Defaults to `"0.0.0"`
    /// when unavailable (e.g. in SPM test runs where `Bundle.main` belongs to
    /// the XCTest host). Written into backup metadata for diagnostic use.
    var appVersion: String {
        (Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String) ?? "0.0.0"
    }
}
