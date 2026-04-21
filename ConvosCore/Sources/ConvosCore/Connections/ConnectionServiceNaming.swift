import Foundation

/// Translates between the canonical service names used in grant metadata
/// (e.g. `google_calendar`) and the Composio toolkit slugs (`googlecalendar`)
/// expected by Composio's API.
///
/// The runtime's `connections.mjs` stores grants keyed by canonical name and
/// translates to the slug only when calling Composio. iOS mirrors that split:
/// canonical everywhere internally, slug only when talking to the backend's
/// /initiate endpoint.
public enum ConnectionServiceNaming {
    /// Canonical service name -> Composio toolkit slug. Omitted services
    /// pass through unchanged (i.e. canonical == slug, as for `slack`, `github`, etc.).
    private static let canonicalToComposioSlug: [String: String] = [
        "google_calendar": "googlecalendar",
        "google_drive": "googledrive",
    ]

    /// Convert a canonical service name (what iOS stores) to the Composio
    /// toolkit slug (what the backend sends to Composio's API).
    public static func composioToolkitSlug(for canonicalServiceId: String) -> String {
        canonicalToComposioSlug[canonicalServiceId] ?? canonicalServiceId
    }

    /// Convert a Composio toolkit slug received from the backend back to the
    /// canonical service name. Falls back to the slug if no mapping exists.
    public static func canonicalService(fromComposioSlug slug: String) -> String {
        if let canonical = canonicalToComposioSlug.first(where: { $0.value == slug })?.key {
            return canonical
        }
        return slug
    }
}
