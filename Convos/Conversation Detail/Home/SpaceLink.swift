import Foundation

/// Whether a URL points into a conversation's own Space - the site the Home
/// surface loads.
///
/// Matching is by origin: scheme, host and port. Every Space is its own
/// subdomain (`https://<id>.spaces.convos.org`), so the host alone identifies
/// one, and nothing outside it can claim a match - including a member posting
/// a lookalike. Path, query and fragment are free, because those are the pages
/// within the Space.
enum SpaceLink {
    /// Whether `url` is a page in `space`.
    static func matches(_ url: URL, space: URL) -> Bool {
        guard let urlOrigin = origin(of: url),
              let spaceOrigin = origin(of: space) else {
            return false
        }
        return urlOrigin == spaceOrigin
    }

    /// Whether `url` is the Space's own root - the page the Home is already
    /// showing. A trailing slash and a fragment leave it the same page; a
    /// query does not, because the site can read one.
    static func isRoot(_ url: URL, space: URL) -> Bool {
        guard matches(url, space: space),
              let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              components.query == nil else {
            return false
        }
        return components.path.isEmpty || components.path == "/"
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
        let port = components.port.map { ":\($0)" } ?? ""
        return "\(scheme)://\(host)\(port)"
    }
}
