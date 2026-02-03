import ArgumentParser
import ConvosCore
import Foundation

/// Central context for CLI that manages ConvosClient initialization
public final class CLIContext: @unchecked Sendable {
    public let client: ConvosClient
    public let dataDirectory: DataDirectory
    public let environment: CLIEnvironment

    nonisolated(unsafe) private static var _shared: CLIContext?
    private static let initLock: NSLock = NSLock()

    private init(client: ConvosClient, dataDirectory: DataDirectory, environment: CLIEnvironment) {
        self.client = client
        self.dataDirectory = dataDirectory
        self.environment = environment
    }

    /// Initialize or get the shared CLI context
    public static func shared(
        dataDir: String? = nil,
        environment: CLIEnvironment = .dev,
        verbose: Bool = false
    ) async throws -> CLIContext {
        // Configure RUST_LOG to suppress XMTP Rust library logs unless verbose
        // This must be set before any XMTP operations
        if ProcessInfo.processInfo.environment["RUST_LOG"] == nil {
            setenv("RUST_LOG", verbose ? "info" : "error", 1)
        }

        // Quick check without lock
        if let existing = _shared {
            return existing
        }

        // Use synchronous initialization to avoid async lock issues
        return try initLock.withLock {
            // Double-check after acquiring lock
            if let existing = _shared {
                return existing
            }

            // Resolve data directory
            let dataDirectory = DataDirectory.resolve(override: dataDir)
            try dataDirectory.ensureExists()

            // Configure platform providers
            let providers = PlatformProviders.cli

            // Configure DeviceInfo and PushNotificationRegistrar globals
            DeviceInfo.configure(providers.deviceInfo)
            PushNotificationRegistrar.configure(providers.pushNotificationRegistrar)

            // Create ConvosCore configuration
            // skipBackendAuth: true disables Firebase App Check which isn't supported on macOS
            // useLocalKeychain: true uses local keychain without access group (no entitlements needed)
            let config = ConvosConfiguration(
                apiBaseURL: environment.apiBaseURL,
                appGroupIdentifier: environment.appGroupIdentifier,
                relyingPartyIdentifier: environment.relyingPartyIdentifier,
                xmtpNetwork: environment.xmtpNetwork,
                databaseDirectoryURL: dataDirectory.databaseDirectoryURL,
                skipBackendAuth: true,
                useLocalKeychain: true
            )

            // Create app environment
            let appEnvironment = AppEnvironment.configured(config, type: environment.environmentType)

            // Initialize ConvosClient
            let client = ConvosClient.client(
                environment: appEnvironment,
                platformProviders: providers
            )

            let context = CLIContext(client: client, dataDirectory: dataDirectory, environment: environment)
            _shared = context
            return context
        }
    }

    /// Access the session manager for messaging operations
    public var session: any SessionManagerProtocol {
        client.session
    }
}

/// CLI environment configuration
public enum CLIEnvironment: String, CaseIterable, ExpressibleByArgument {
    case local
    case dev
    case production

    var apiBaseURL: String {
        switch self {
        case .local:
            return "http://localhost:4000/api"
        case .dev:
            return "https://api.dev.convos.xyz/api"
        case .production:
            return "https://api.prod.convos.xyz/api"
        }
    }

    var appGroupIdentifier: String {
        switch self {
        case .local:
            return "group.org.convos.ios-local"
        case .dev:
            return "group.org.convos.ios-dev"
        case .production:
            return "group.org.convos.ios"
        }
    }

    var relyingPartyIdentifier: String {
        switch self {
        case .local:
            return "local.convos.org"
        case .dev:
            return "dev.convos.org"
        case .production:
            return "convos.org"
        }
    }

    var xmtpNetwork: String? {
        switch self {
        case .local:
            return "local"
        case .dev:
            return "dev"
        case .production:
            return "production"
        }
    }

    var environmentType: AppEnvironment.EnvironmentType {
        switch self {
        case .local:
            return .local
        case .dev:
            return .dev
        case .production:
            return .production
        }
    }

    /// Domain for generating invite URLs
    public var inviteDomain: String {
        switch self {
        case .local:
            return "local.convos.org"
        case .dev:
            return "dev.convos.org"
        case .production:
            return "convos.org"
        }
    }
}
