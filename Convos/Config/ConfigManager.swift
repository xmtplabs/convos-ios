import ConvosCore
import Foundation

/// Simple config loader that overrides AppEnvironment values per build
final class ConfigManager {
    static let shared: ConfigManager = ConfigManager()

    private let config: [String: Any]
    private var _currentEnvironment: AppEnvironment?
    private let environmentLock: NSLock = NSLock()

    private init() {
        guard let url = Bundle.main.url(forResource: "config", withExtension: "json"),
              let data = try? Data(contentsOf: url),
              let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            fatalError("Missing or malformed config.json - ensure build phase copies correct config file")
        }
        self.config = dict
    }

    /// Get the current AppEnvironment from config (thread-safe)
    var currentEnvironment: AppEnvironment {
        // First check without lock (fast path)
        environmentLock.lock()
        if let environment = _currentEnvironment {
            environmentLock.unlock()
            return environment
        }
        environmentLock.unlock()

        // Create environment outside the lock to avoid holding lock during potential fatalError
        let environment = createEnvironment()

        // Double-checked locking: re-check after creating to prevent race condition
        environmentLock.lock()
        if let existingEnvironment = _currentEnvironment {
            // Another thread initialized it while we were creating
            environmentLock.unlock()
            return existingEnvironment
        }
        _currentEnvironment = environment
        environmentLock.unlock()

        // Store the environment configuration securely for the notification extension
        // Only the thread that won the race should perform this side effect
        environment.storeSecureConfigurationForNotificationExtension()

        return environment
    }

    /// Checks if a string is empty or contains only whitespace
    private func isEmptyOrWhitespace(_ string: String) -> Bool {
        string.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private func resolveAndValidateURL(secretsOverride: String, configDefault: String?, environmentName: String) -> String {
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

        let environment: AppEnvironment

        // Two-tier priority: Bash script (generate-secrets-local.sh) writes prioritized value to Secrets.
        // Priority: .env > auto-detected IP > config.json
        // This code: Use Secrets if non-empty, else fallback to config.json (safety when Secrets fails)
        switch envString {
        case "local":
            let url = resolveAndValidateURL(
                secretsOverride: Secrets.CONVOS_API_BASE_URL,
                configDefault: apiBaseURL,
                environmentName: "local"
            )
            let config = ConvosConfiguration(
                apiBaseURL: url,
                appGroupIdentifier: appGroupIdentifier,
                relyingPartyIdentifier: relyingPartyIdentifier,
                xmtpEndpoint: isEmptyOrWhitespace(Secrets.XMTP_CUSTOM_HOST) ? nil : Secrets.XMTP_CUSTOM_HOST.trimmingCharacters(in: .whitespacesAndNewlines),
                xmtpNetwork: xmtpNetwork,
                gatewayUrl: isEmptyOrWhitespace(Secrets.GATEWAY_URL) ? nil : Secrets.GATEWAY_URL.trimmingCharacters(in: .whitespacesAndNewlines),
                assetsCdnUrl: assetsCdnUrl
            )
            environment = .local(config: config)

        case "dev":
            // Allow override via Secrets for dev environment (useful for local backend testing)
            let url = resolveAndValidateURL(
                secretsOverride: Secrets.CONVOS_API_BASE_URL,
                configDefault: apiBaseURL,
                environmentName: "dev"
            )
            let config = ConvosConfiguration(
                apiBaseURL: url,
                appGroupIdentifier: appGroupIdentifier,
                relyingPartyIdentifier: relyingPartyIdentifier,
                xmtpEndpoint: isEmptyOrWhitespace(Secrets.XMTP_CUSTOM_HOST) ? nil : Secrets.XMTP_CUSTOM_HOST.trimmingCharacters(in: .whitespacesAndNewlines),
                xmtpNetwork: xmtpNetwork,
                assetsCdnUrl: assetsCdnUrl
            )
            environment = .dev(config: config)

        case "production":
            let url = resolveAndValidateURL(
                secretsOverride: Secrets.CONVOS_API_BASE_URL,
                configDefault: apiBaseURL,
                environmentName: "production"
            )
            let config = ConvosConfiguration(
                apiBaseURL: url,
                appGroupIdentifier: appGroupIdentifier,
                relyingPartyIdentifier: relyingPartyIdentifier,
                xmtpNetwork: xmtpNetwork,
                assetsCdnUrl: assetsCdnUrl
            )
            environment = .production(config: config)

        default:
            fatalError("Invalid environment '\(envString)' in config.json")
        }

        return environment
    }

    /// API base URL from config.json (used as default/fallback when Secrets not provided)
    var apiBaseURL: String? {
        config["backendUrl"] as? String
    }

    /// Bundle identifier from config
    var bundleIdentifier: String {
        guard let id = config["bundleId"] as? String else {
            fatalError("Missing 'bundleId' in config.json")
        }
        return id
    }

    /// App group identifier from config
    var appGroupIdentifier: String {
        guard let id = config["appGroupIdentifier"] as? String else {
            fatalError("Missing 'appGroupIdentifier' in config.json")
        }
        return id
    }

    /// Relying party identifier from config
    var relyingPartyIdentifier: String {
        guard let id = config["relyingPartyIdentifier"] as? String else {
            fatalError("Missing 'relyingPartyIdentifier' in config.json")
        }
        return id
    }

    /// Associated domain from config (matches ASSOCIATED_DOMAIN from xcconfig)
    var associatedDomain: String {
        guard let domain = associatedDomains.first else {
            fatalError("associatedDomains is empty")
        }
        return domain
    }

    /// All associated domains from config (primary first).
    /// Supports new `associatedDomains` array, but falls back to legacy single `associatedDomain` string.
    var associatedDomains: [String] {
        if let domains = config["associatedDomains"] as? [String], !domains.isEmpty {
            return domains
        }
        if let single = config["associatedDomain"] as? String {
            return [single]
        }
        fatalError("Missing 'associatedDomains' or 'associatedDomain' in config.json")
    }

    /// App URL scheme from config
    var appUrlScheme: String {
        guard let scheme = config["appUrlScheme"] as? String else {
            fatalError("Missing 'appUrlScheme' in config.json")
        }
        return scheme
    }

    /// XMTP Network from config (optional, validated)
    var xmtpNetwork: String? {
        guard let network = config["xmtpNetwork"] as? String else {
            return nil
        }

        let validNetworks = ["local", "dev", "production", "prod"]
        let normalizedNetwork = network.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)

        guard validNetworks.contains(normalizedNetwork) else {
            fatalError("Invalid 'xmtpNetwork' value '\(network)' in config.json. Must be one of: local, dev, production, prod")
        }

        return normalizedNetwork
    }

    /// Assets CDN URL from config (optional, for dev/prod environments)
    var assetsCdnUrl: String? {
        config["assetsCdnUrl"] as? String
    }
}
