import Foundation
import os

/// Resolves asset keys to full CDN URLs
///
/// Asset keys are stored without the CDN domain to save space in QR codes and group metadata.
/// This resolver converts between the stored key format and full URLs.
///
/// This resolver only returns URLs pointing to allowed asset hosts (CDN + legacy S3).
/// Full URLs from untrusted sources are rejected unless they match an allowed host.
///
/// Example:
/// - Stored key: `a75e060a-1694-41de-8e6d-ca28a12fc62f.jpeg`
/// - Full URL: `https://assets.prod.convos.xyz/a75e060a-1694-41de-8e6d-ca28a12fc62f.jpeg`
public final class AssetURLResolver: Sendable {
    public static let shared: AssetURLResolver = AssetURLResolver()

    /// Stores the primary CDN config and allowed hosts
    private struct Config: Sendable {
        /// Primary CDN base URL (used for building URLs from asset keys)
        let primaryBaseURL: URL
        /// All allowed hosts (lowercase) including the primary CDN
        let allowedHosts: Set<String>
    }

    private let config: OSAllocatedUnfairLock<Config?>

    private init() {
        self.config = OSAllocatedUnfairLock(initialState: nil)
    }

    /// Configure the resolver with the CDN base URL and allowed hosts
    ///
    /// - Parameters:
    ///   - cdnBaseURL: Primary CDN base URL (used for building URLs from asset keys)
    ///   - allowedHosts: List of allowed hostnames (CDN + legacy S3 buckets)
    public func configure(cdnBaseURL: String?, allowedHosts: [String] = []) {
        guard let cdnBaseURL, !cdnBaseURL.isEmpty else {
            config.withLock { $0 = nil }
            return
        }

        // Validate and parse the primary CDN URL
        guard let url = URL(string: cdnBaseURL),
              let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https",
              let primaryHost = url.host, !primaryHost.isEmpty else {
            Log.error("AssetURLResolver: Invalid CDN base URL configured: \(cdnBaseURL)")
            config.withLock { $0 = nil }
            return
        }

        // Build the set of allowed hosts (all lowercase for case-insensitive matching)
        var hosts = Set(allowedHosts.map { $0.lowercased() })
        hosts.insert(primaryHost.lowercased()) // Always include the primary CDN host

        let resolvedConfig = Config(primaryBaseURL: url, allowedHosts: hosts)
        config.withLock { $0 = resolvedConfig }

        Log.info("AssetURLResolver: Configured with \(hosts.count) allowed host(s)")
    }

    /// Resolves an asset value to a full URL
    ///
    /// Handles these cases:
    /// 1. Already a URL from an allowed host - validates and returns
    /// 2. Asset key with configured CDN - prepends primary CDN base URL
    /// 3. URL from non-allowed host - returns nil (security)
    /// 4. No CDN configured - returns nil
    ///
    /// - Parameter assetValue: Either a full URL string or an asset key
    /// - Returns: The resolved URL, or nil if resolution fails or URL is not from an allowed host
    public func resolveURL(from assetValue: String?) -> URL? {
        guard let assetValue, !assetValue.isEmpty else {
            return nil
        }

        let resolvedConfig = config.withLock { $0 }

        // Check if input is already a full URL
        if let inputURL = URL(string: assetValue),
           let scheme = inputURL.scheme?.lowercased(),
           scheme == "http" || scheme == "https" {
            // Security: Only allow URLs from configured hosts
            guard let resolvedConfig,
                  let inputHost = inputURL.host?.lowercased(),
                  resolvedConfig.allowedHosts.contains(inputHost) else {
                Log.warning("AssetURLResolver: Rejected URL from non-allowed host: \(URL(string: assetValue)?.host ?? "nil")")
                return nil
            }
            return inputURL
        }

        // It's an asset key - validate we have CDN configured
        guard let resolvedConfig else {
            Log.warning("AssetURLResolver: No CDN configured, cannot resolve asset key: \(assetValue)")
            return nil
        }

        // Sanitize the asset key
        guard let cleanKey = sanitizeAssetKey(assetValue) else {
            Log.warning("AssetURLResolver: Invalid asset key: \(assetValue)")
            return nil
        }

        // Build URL using the primary CDN
        // Append each path component separately to preserve slashes in multi-segment keys
        var url = resolvedConfig.primaryBaseURL
        for component in cleanKey.split(separator: "/") {
            url.appendPathComponent(String(component))
        }
        return url
    }

    /// Sanitizes an asset key, returning nil if invalid
    ///
    /// - Removes leading/trailing slashes
    /// - Rejects empty keys
    /// - Rejects keys with path traversal attempts
    private func sanitizeAssetKey(_ key: String) -> String? {
        // Trim whitespace and slashes
        var cleanKey = key.trimmingCharacters(in: .whitespacesAndNewlines)
        cleanKey = cleanKey.trimmingCharacters(in: CharacterSet(charactersIn: "/"))

        // Reject empty keys
        guard !cleanKey.isEmpty else {
            return nil
        }

        // Reject path traversal attempts
        if cleanKey.contains("..") || cleanKey.contains("//") {
            Log.warning("AssetURLResolver: Rejected key with path traversal: \(key)")
            return nil
        }

        return cleanKey
    }

    /// Extracts the asset key from a full URL or returns the value if already a key
    ///
    /// Use this when storing asset URLs to extract just the key portion.
    /// Only extracts keys from allowed hosts - rejects URLs from unknown domains.
    ///
    /// - Parameter urlString: A full URL string or asset key
    /// - Returns: The asset key, or nil if extraction fails or URL is from non-allowed host
    public func extractAssetKey(from urlString: String?) -> String? {
        guard let urlString, !urlString.isEmpty else {
            return nil
        }

        // If it's not a full URL, assume it's already an asset key
        guard let inputURL = URL(string: urlString),
              let scheme = inputURL.scheme?.lowercased(),
              scheme == "http" || scheme == "https" else {
            // Validate as asset key
            return sanitizeAssetKey(urlString)
        }

        let resolvedConfig = config.withLock { $0 }

        // Security: Only extract keys from allowed hosts
        guard let resolvedConfig,
              let inputHost = inputURL.host?.lowercased(),
              resolvedConfig.allowedHosts.contains(inputHost) else {
            Log.warning("AssetURLResolver: Cannot extract key from non-allowed host: \(inputURL.host ?? "nil")")
            return nil
        }

        // Extract full path as key and sanitize
        let key = inputURL.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard !key.isEmpty else { return nil }
        return sanitizeAssetKey(key)
    }
}
