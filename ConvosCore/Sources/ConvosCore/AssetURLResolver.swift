import Foundation
import os

/// Validates and resolves asset URLs from trusted sources
///
/// With the new API, the backend provides complete asset URLs (assetUrl) rather than just keys.
/// This resolver validates that URLs come from allowed hosts for security.
///
/// This resolver only returns URLs pointing to allowed asset hosts (CDN + legacy S3).
/// Full URLs from untrusted sources are rejected unless they match an allowed host.
///
/// Example:
/// - Input: `https://assets.prod.convos.xyz/a75e060a-1694-41de-8e6d-ca28a12fc62f.jpeg`
/// - Output: Same URL (after validation against allowed hosts)
public final class AssetURLResolver: Sendable {
    public static let shared: AssetURLResolver = AssetURLResolver()

    /// Stores the allowed hosts for security validation
    private struct Config: Sendable {
        /// All allowed hosts (lowercase) for validating asset URLs
        let allowedHosts: Set<String>
    }

    private let config: OSAllocatedUnfairLock<Config?>

    private init() {
        self.config = OSAllocatedUnfairLock(initialState: nil)
    }

    /// Configure the resolver with allowed asset hosts
    ///
    /// - Parameters:
    ///   - allowedHosts: List of allowed hostnames (CDN + legacy S3 buckets)
    public func configure(allowedHosts: [String] = []) {
        guard !allowedHosts.isEmpty else {
            Log.warning("No allowed hosts configured - all asset URLs will be rejected")
            config.withLock { $0 = nil }
            return
        }

        // Build the set of allowed hosts (all lowercase for case-insensitive matching)
        let hosts = Set(
            allowedHosts
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
                .filter { !$0.isEmpty }
        )

        guard !hosts.isEmpty else {
            Log.warning("No valid allowed hosts after filtering")
            config.withLock { $0 = nil }
            return
        }

        let resolvedConfig = Config(allowedHosts: hosts)
        config.withLock { $0 = resolvedConfig }

        Log.info("Configured with \(hosts.count) allowed host(s): \(Array(hosts).joined(separator: ", "))")
    }

    /// Validates a remote asset URL against allowed hosts
    ///
    /// With the new API, the backend provides complete URLs (assetUrl field).
    /// This method validates that URLs come from allowed hosts for security.
    ///
    /// Only http/https URLs are accepted; local file:// URLs should be handled
    /// directly by the caller (e.g., quickname preview) without going through this resolver.
    ///
    /// - Parameter assetValue: A full URL string (e.g., from backend's assetUrl field)
    /// - Returns: The validated URL, or nil if validation fails or URL is not from an allowed host
    public func resolveURL(from assetValue: String?) -> URL? {
        guard let assetValue, !assetValue.isEmpty else {
            return nil
        }

        // Parse as URL
        guard let inputURL = URL(string: assetValue),
              let scheme = inputURL.scheme?.lowercased() else {
            Log.warning("Invalid URL format: \(assetValue)")
            return nil
        }

        // Only allow http/https; local file URLs should be handled directly by callers
        guard scheme == "http" || scheme == "https" else {
            Log.warning("Rejected URL with unsupported scheme: \(scheme)")
            return nil
        }

        // Validate against allowed hosts
        guard let resolvedConfig = config.withLock({ $0 }) else {
            Log.warning("No allowed hosts configured, rejecting URL: \(assetValue)")
            return nil
        }

        guard let inputHost = inputURL.host?.lowercased(),
              resolvedConfig.allowedHosts.contains(inputHost) else {
            Log.warning("Rejected URL from non-allowed host: \(inputURL.host ?? "nil")")
            return nil
        }

        return inputURL
    }
}
