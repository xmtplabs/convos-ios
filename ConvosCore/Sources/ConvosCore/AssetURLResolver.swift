import Foundation

/// Resolves asset keys to full CDN URLs
///
/// Asset keys are stored without the CDN domain to save space in QR codes and group metadata.
/// This resolver converts between the stored key format and full URLs.
///
/// Example:
/// - Stored key: `a75e060a-1694-41de-8e6d-ca28a12fc62f.jpeg`
/// - Full URL: `https://d32k96dpvyy43a.cloudfront.net/a75e060a-1694-41de-8e6d-ca28a12fc62f.jpeg`
public final class AssetURLResolver: @unchecked Sendable {
    public static let shared: AssetURLResolver = AssetURLResolver()

    private var cdnBaseURL: String?
    private let lock: NSLock = NSLock()

    private init() {}

    /// Configure the resolver with the CDN base URL (without trailing slash)
    /// Call this once at app startup with the environment's assetsCdnUrl
    public func configure(cdnBaseURL: String?) {
        lock.lock()
        defer { lock.unlock() }
        self.cdnBaseURL = cdnBaseURL
    }

    /// Resolves an asset value to a full URL
    ///
    /// Handles three cases:
    /// 1. Already a full URL (http:// or https://) - returns as-is
    /// 2. Asset key with configured CDN - prepends CDN base URL
    /// 3. Asset key without CDN configured - returns nil (local environment)
    ///
    /// - Parameter assetValue: Either a full URL string or an asset key
    /// - Returns: The resolved URL, or nil if resolution fails
    public func resolveURL(from assetValue: String?) -> URL? {
        guard let assetValue, !assetValue.isEmpty else {
            return nil
        }

        // If already a full URL, return it directly
        if assetValue.hasPrefix("http://") || assetValue.hasPrefix("https://") {
            return URL(string: assetValue)
        }

        // Otherwise, it's an asset key - prepend the CDN base URL
        lock.lock()
        let baseURL = cdnBaseURL
        lock.unlock()

        guard let baseURL, !baseURL.isEmpty else {
            // No CDN configured (local environment) - can't resolve
            Log.warning("AssetURLResolver: No CDN configured, cannot resolve asset key: \(assetValue)")
            return nil
        }

        // Remove any leading slash from the asset key
        let cleanKey = assetValue.hasPrefix("/") ? String(assetValue.dropFirst()) : assetValue
        let fullURLString = "\(baseURL)/\(cleanKey)"
        return URL(string: fullURLString)
    }

    /// Extracts the asset key from a full URL or returns the value if already a key
    ///
    /// Use this when storing asset URLs to extract just the key portion.
    /// Returns nil if the URL doesn't match the configured CDN.
    ///
    /// - Parameter urlString: A full URL string or asset key
    /// - Returns: The asset key, or nil if not a CDN URL
    public func extractAssetKey(from urlString: String?) -> String? {
        guard let urlString, !urlString.isEmpty else {
            return nil
        }

        // If it's not a full URL, assume it's already an asset key
        guard urlString.hasPrefix("http://") || urlString.hasPrefix("https://") else {
            return urlString
        }

        lock.lock()
        let baseURL = cdnBaseURL
        lock.unlock()

        // Check if it matches our CDN using proper URL parsing to prevent spoofed domains
        if let baseURL,
           let cdnURL = URL(string: baseURL),
           let inputURL = URL(string: urlString),
           inputURL.host == cdnURL.host,
           inputURL.scheme == cdnURL.scheme {
            let key = inputURL.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            return key.isEmpty ? nil : key
        }

        // Check for legacy S3 URLs and extract just the filename/key
        // Pattern: https://convos-assets-*.s3.*.amazonaws.com/{key}
        if urlString.contains("s3.") && urlString.contains("amazonaws.com") {
            if let url = URL(string: urlString) {
                let key = url.lastPathComponent
                return key.isEmpty ? nil : key
            }
        }

        // Not a recognized CDN URL - return nil to keep the full URL
        return nil
    }
}
