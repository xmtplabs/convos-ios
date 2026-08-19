import Foundation

/// Whether a URL points into a conversation's own Space - the site the Home
/// surface loads.
///
/// Matching is by origin: scheme, host and port. Every Space is its own
/// subdomain, so the host alone identifies one, and nothing outside it can
/// claim a match - including a member posting a lookalike. Path, query and
/// fragment are free, because those are the pages within the Space.
public enum SpaceLink {
    /// Whether `url` is a page in `space`.
    public static func matches(_ url: URL, space: URL) -> Bool {
        guard let urlOrigin = origin(of: url),
              let spaceOrigin = origin(of: space) else {
            return false
        }
        return urlOrigin == spaceOrigin
    }

    /// Whether `url` is the Space's own root - the page the Home is already
    /// showing. A trailing slash and a fragment leave it the same page; a
    /// query does not, because the site can read one.
    public static func isRoot(_ url: URL, space: URL) -> Bool {
        guard matches(url, space: space),
              let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              components.query == nil else {
            return false
        }
        return normalizedPath(components.path).isEmpty
    }

    /// Whether two URLs address the same page, for deciding that a tap has
    /// nowhere to go: origin, path and query must agree.
    ///
    /// The fragment is excluded. `#section` scrolls the page that is already
    /// open rather than opening another one - the same call `HomeWebNavigation`
    /// makes when the page itself navigates.
    public static func isSamePage(_ url: URL, as other: URL) -> Bool {
        guard let lhs = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let rhs = URLComponents(url: other, resolvingAgainstBaseURL: false),
              let lhsOrigin = origin(of: url),
              let rhsOrigin = origin(of: other) else {
            return false
        }
        return lhsOrigin == rhsOrigin
            && normalizedPath(lhs.path) == normalizedPath(rhs.path)
            && lhs.query == rhs.query
    }

    /// Whether `url` addresses the same page *and* the same place within it.
    ///
    /// The stricter of the two: a differing fragment is somewhere on the page
    /// the reader is not, and nothing here can scroll a page that is already
    /// open, so the caller has to treat it as somewhere to go.
    public static func isSameLocation(_ url: URL, as other: URL) -> Bool {
        guard isSamePage(url, as: other) else { return false }
        return URLComponents(url: url, resolvingAgainstBaseURL: false)?.fragment
            == URLComponents(url: other, resolvingAgainstBaseURL: false)?.fragment
    }

    /// Paths that differ only by a trailing slash are one page, and so are
    /// "" and "/".
    private static func normalizedPath(_ path: String) -> String {
        var trimmed = path
        while trimmed.hasSuffix("/") {
            trimmed.removeLast()
        }
        return trimmed
    }

    /// `scheme://host[:port]`, lowercased, or nil for anything that is not a
    /// resolvable https origin.
    ///
    /// https only: a Space is served over TLS, and letting a plain-text
    /// lookalike match would hand it the trust the match carries.
    private static func origin(of url: URL) -> String? {
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let scheme = components.scheme?.lowercased(), scheme == "https",
              let host = components.host?.lowercased(), !host.isEmpty else {
            return nil
        }
        // 443 is what https means, so a URL that spells it out addresses the
        // same origin as one that leaves it off.
        let port = components.port.flatMap { $0 == 443 ? nil : ":\($0)" } ?? ""
        return "\(scheme)://\(host)\(port)"
    }
}
