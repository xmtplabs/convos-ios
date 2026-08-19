import ConvosCore
import UIKit

/// Memory-and-disk caching for the backend-served ability icons, layered on
/// the app's shared `ImageCache`.
///
/// The icons are versioned, immutable PNGs with an alpha channel - the
/// backend serves `/ability-icons/<slug>-v<n>.png` with
/// `Cache-Control: immutable, max-age=1y` - so the URL is a permanent cache
/// key that never needs revalidating, and a bumped icon keys separately
/// instead of serving the previous bytes.
///
/// They use the cache's identifier-based API rather than the object-based
/// `ImageCacheable` path because that path persists to disk as JPEG, which
/// would flatten each icon's transparency onto an opaque square from the
/// first cold launch onwards.
enum AbilityIconLoader {
    /// The memory hit, synchronously. Non-nil means a view can draw the icon
    /// in its first frame, which is what keeps a re-rendered row from
    /// flashing its symbol placeholder.
    static func cachedIcon(for url: URL) -> UIImage? {
        ImageCache.shared.image(for: cacheKey(for: url), imageFormat: .png)
    }

    /// Memory, then disk, then the network - caching at whichever step it had
    /// to descend to.
    static func icon(for url: URL) async -> UIImage? {
        let key = cacheKey(for: url)
        if let cached = await ImageCache.shared.imageAsync(for: key, imageFormat: .png) {
            return cached
        }
        guard let fetched = await fetchIcon(at: url) else { return nil }
        ImageCache.shared.cacheImage(fetched, for: key, imageFormat: .png)
        return fetched
    }

    /// Namespaced so an icon URL can never collide with another cache client's
    /// identifier space.
    static func cacheKey(for url: URL) -> String {
        "ability-icon-\(url.absoluteString)"
    }

    private static func fetchIcon(at url: URL) async -> UIImage? {
        // SwiftUI previews hand over a data: URI so they need no network, and
        // URLSession does not serve that scheme.
        if url.scheme == "data" {
            return (try? Data(contentsOf: url)).flatMap { UIImage(data: $0) }
        }
        do {
            let (data, response) = try await URLSession.shared.data(from: url)
            guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
                Log.error("Ability icon fetch failed for \(url): unexpected response")
                return nil
            }
            guard let image = UIImage(data: data) else {
                Log.error("Ability icon at \(url) could not be decoded")
                return nil
            }
            return image
        } catch {
            Log.error("Ability icon fetch failed for \(url): \(error)")
            return nil
        }
    }
}
