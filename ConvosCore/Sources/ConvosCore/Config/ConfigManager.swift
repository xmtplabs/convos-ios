import Foundation

/// Per-build secret overrides sourced from the app target's `Secrets.swift`.
/// Values default to empty strings; `ConfigManager` falls back to the
/// matching config.json defaults when a field is empty.
public struct ConvosSecretOverrides: Sendable {
    public let apiBaseURL: String
    public let xmtpCustomHost: String
    public let gatewayURL: String

    public init(apiBaseURL: String, xmtpCustomHost: String, gatewayURL: String) {
        self.apiBaseURL = apiBaseURL
        self.xmtpCustomHost = xmtpCustomHost
        self.gatewayURL = gatewayURL
    }

    public static let empty: ConvosSecretOverrides = .init(
        apiBaseURL: "",
        xmtpCustomHost: "",
        gatewayURL: ""
    )
}

/// Loads per-build configuration from the `config.json` bundle resource and
/// materializes the matching `AppEnvironment`. The main app, the App Clip,
/// and any other entry point that needs a configured environment should call
/// `ConfigManager.configure(overrides:)` once at startup (before reading
/// `shared`) so the singleton can merge Secrets overrides with config.json
/// defaults.
public final class ConfigManager: @unchecked Sendable {
    private static let registrationLock: NSLock = NSLock()
    nonisolated(unsafe) private static var _shared: ConfigManager?

    /// Install the shared instance. Safe to call multiple times from the same
    /// process — subsequent calls are ignored. The first invocation wins so
    /// early readers never observe a reconfigured instance.
    public static func configure(overrides: ConvosSecretOverrides) {
        registrationLock.lock()
        defer { registrationLock.unlock() }
        guard _shared == nil else { return }
        _shared = ConfigManager(overrides: overrides)
    }

    public static var shared: ConfigManager {
        registrationLock.lock()
        defer { registrationLock.unlock() }
        guard let instance = _shared else {
            fatalError("ConfigManager.shared accessed before configure(overrides:) was called")
        }
        return instance
    }

    private let config: [String: Any]
    private let overrides: ConvosSecretOverrides
    private var _currentEnvironment: AppEnvironment?
    private let environmentLock: NSLock = NSLock()

    private init(overrides: ConvosSecretOverrides) {
        guard let url = Bundle.main.url(forResource: "config", withExtension: "json"),
              let data = try? Data(contentsOf: url),
              let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            fatalError("Missing or malformed config.json - ensure build phase copies correct config file")
        }
        self.config = dict
        self.overrides = overrides
    }

    /// Resolved `AppEnvironment` for the current build. Thread-safe and
    /// memoized after the first call.
    public var currentEnvironment: AppEnvironment {
        environmentLock.lock()
        if let environment = _currentEnvironment {
            environmentLock.unlock()
            return environment
        }
        environmentLock.unlock()

        let environment = createEnvironment()

        environmentLock.lock()
        if let existing = _currentEnvironment {
            environmentLock.unlock()
            return existing
        }
        _currentEnvironment = environment
        environmentLock.unlock()

        environment.storeSecureConfigurationForNotificationExtension()

        return environment
    }

    private func isEmptyOrWhitespace(_ string: String) -> Bool {
        string.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private func resolveAndValidateURL(
        secretsOverride: String,
        configDefault: String?,
        environmentName: String
    ) -> String {
        let url = (isEmptyOrWhitespace(secretsOverride) ? (configDefault ?? "") : secretsOverride)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !url.isEmpty else {
            fatalError("Missing 'backendUrl' for \(environmentName) environment (Secrets or config.json)")
        }
        guard URL(string: url) != nil else {
            fatalError("Invalid API URL for \(environmentName) environment: '\(url)'")
        }
        return url
    }

    private func createEnvironment() -> AppEnvironment {
        guard let envString = config["environment"] as? String else {
            fatalError("Missing 'environment' key in config.json")
        }

        let xmtpEndpoint: String? = isEmptyOrWhitespace(overrides.xmtpCustomHost)
            ? nil
            : overrides.xmtpCustomHost.trimmingCharacters(in: .whitespacesAndNewlines)
        let gatewayUrl: String? = isEmptyOrWhitespace(overrides.gatewayURL)
            ? nil
            : overrides.gatewayURL.trimmingCharacters(in: .whitespacesAndNewlines)

        switch envString {
        case "local":
            let url = resolveAndValidateURL(
                secretsOverride: overrides.apiBaseURL,
                configDefault: apiBaseURL,
                environmentName: "local"
            )
            let config = ConvosConfiguration(
                apiBaseURL: url,
                appGroupIdentifier: appGroupIdentifier,
                relyingPartyIdentifier: relyingPartyIdentifier,
                xmtpEndpoint: xmtpEndpoint,
                xmtpNetwork: xmtpNetwork,
                gatewayUrl: gatewayUrl
            )
            return .local(config: config)

        case "dev":
            let url = resolveAndValidateURL(
                secretsOverride: overrides.apiBaseURL,
                configDefault: apiBaseURL,
                environmentName: "dev"
            )
            let config = ConvosConfiguration(
                apiBaseURL: url,
                appGroupIdentifier: appGroupIdentifier,
                relyingPartyIdentifier: relyingPartyIdentifier,
                xmtpEndpoint: xmtpEndpoint,
                xmtpNetwork: xmtpNetwork
            )
            return .dev(config: config)

        case "production":
            let url = resolveAndValidateURL(
                secretsOverride: overrides.apiBaseURL,
                configDefault: apiBaseURL,
                environmentName: "production"
            )
            let config = ConvosConfiguration(
                apiBaseURL: url,
                appGroupIdentifier: appGroupIdentifier,
                relyingPartyIdentifier: relyingPartyIdentifier,
                xmtpNetwork: xmtpNetwork
            )
            return .production(config: config)

        default:
            fatalError("Invalid environment '\(envString)' in config.json")
        }
    }

    /// API base URL from config.json (used as default/fallback when Secrets not provided)
    public var apiBaseURL: String? {
        config["backendUrl"] as? String
    }

    public var bundleIdentifier: String {
        guard let id = config["bundleId"] as? String else {
            fatalError("Missing 'bundleId' in config.json")
        }
        return id
    }

    public var appGroupIdentifier: String {
        guard let id = config["appGroupIdentifier"] as? String else {
            fatalError("Missing 'appGroupIdentifier' in config.json")
        }
        return id
    }

    public var relyingPartyIdentifier: String {
        guard let id = config["relyingPartyIdentifier"] as? String else {
            fatalError("Missing 'relyingPartyIdentifier' in config.json")
        }
        return id
    }

    /// The primary associated domain (first entry of `associatedDomains`).
    public var associatedDomain: String {
        guard let domain = associatedDomains.first else {
            fatalError("associatedDomains is empty")
        }
        return domain
    }

    /// All associated domains from config (primary first).
    /// Accepts the newer `associatedDomains` array; falls back to the legacy
    /// `associatedDomain` single string for older config.json files.
    public var associatedDomains: [String] {
        if let domains = config["associatedDomains"] as? [String], !domains.isEmpty {
            return domains
        }
        if let single = config["associatedDomain"] as? String {
            return [single]
        }
        fatalError("Missing 'associatedDomains' or 'associatedDomain' in config.json")
    }

    public var appUrlScheme: String {
        guard let scheme = config["appUrlScheme"] as? String else {
            fatalError("Missing 'appUrlScheme' in config.json")
        }
        return scheme
    }

    /// XMTP network name from config, if set. Validated against the supported set.
    public var xmtpNetwork: String? {
        guard let network = config["xmtpNetwork"] as? String else {
            return nil
        }
        let valid = ["local", "dev", "production", "prod"]
        let normalized = network.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        guard valid.contains(normalized) else {
            fatalError("Invalid 'xmtpNetwork' value '\(network)' in config.json. Must be one of: local, dev, production, prod")
        }
        return normalized
    }
}
