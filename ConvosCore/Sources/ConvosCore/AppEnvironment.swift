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

    public var siweConfiguration: SIWEConfiguration {
        switch self {
        case .local(let config), .dev(let config), .production(let config):
            return config.siweConfiguration
        case .tests:
            // Tests construct their own SIWEMessage / SIWESigner inputs
            // directly and never read this accessor. The placeholder
            // here exists only to keep the switch exhaustive; it must
            // never reach a real backend.
            return SIWEConfiguration(domain: "tests.invalid", uri: "https://tests.invalid", chainId: 0)
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

    /// True for Dev and Local builds. Gate debug-only UI on this so it
    /// never reaches the App Store build.
    var isInternalBuild: Bool {
        switch self {
        case .dev, .local:
            true
        case .production, .tests:
            false
        }
    }

    var defaultXMTPLogsDirectoryURL: URL {
        guard !isTestingEnvironment else {
            return FileManager.default.temporaryDirectory
        }
        return appGroupContainerURL.appendingPathComponent("logs", isDirectory: true)
    }

    var defaultDatabasesDirectoryURL: URL {
        guard !isTestingEnvironment else {
            return FileManager.default.temporaryDirectory
        }
        return appGroupContainerURL
    }

    /// Shared app-group container, used for logs and databases.
    ///
    /// A nil container is not a simulator limitation -- the simulator honors
    /// app-group entitlements like a device. It means the running build was
    /// not signed with an app-group entitlement that grants
    /// `appGroupIdentifier`. Common causes: the app was built or installed
    /// without the entitlement applied (a simulator build needs
    /// `-configuration Local` or `Dev`, not the default Release), or
    /// config.json's `appGroupIdentifier` does not match the build
    /// configuration's `APP_GROUP_IDENTIFIER` entitlement. The message names
    /// the requested identifier and bundle id so the mismatch is obvious.
    private var appGroupContainerURL: URL {
        guard let groupUrl = FileManager.default.containerURL(
            forSecurityApplicationGroupIdentifier: appGroupIdentifier
        ) else {
            let bundleId = Bundle.main.bundleIdentifier ?? "unknown"
            let message = """
            Could not resolve the app group container for '\(appGroupIdentifier)'. \
            The running build's app-group entitlement does not grant this identifier. \
            Verify the app was built and installed with its entitlement applied \
            (simulator builds need -configuration Local or Dev) and that config.json's \
            appGroupIdentifier matches the build configuration's APP_GROUP_IDENTIFIER. \
            Bundle id: \(bundleId).
            """
            fatalError(message)
        }
        return groupUrl
    }

    var defaultDatabasesDirectory: String {
        defaultDatabasesDirectoryURL.path
    }
}
