import Foundation

// Endpoint URL construction (internal for tests). Shared by every route
// that carries an opaque identifier in its path — abilities and the
// Space share mint today.

extension ConvosAPIClient {
    /// Percent-encodes one path segment with the RFC 3986 unreserved set
    /// only, so opaque ids containing `/`, `%`, `?`, or `#` stay a single
    /// path component. `.urlPathAllowed` is not enough: it leaves `/`
    /// intact, splitting the id into extra path segments.
    static func strictPathComponentEncoded(_ raw: String) -> String {
        raw.addingPercentEncoding(withAllowedCharacters: Constant.unreservedCharacters) ?? raw
    }

    /// Builds an endpoint URL by setting the percent-encoded path
    /// directly on URLComponents. `appendingPathComponent` cannot be used
    /// with pre-encoded segments: it re-encodes `%` into `%25`, double
    /// encoding the id.
    static func endpointURL(baseURL: URL, pathSegments: [String], queryParameters: [String: String]?) throws -> URL {
        guard var components = URLComponents(url: baseURL, resolvingAgainstBaseURL: false) else {
            throw APIError.invalidURL
        }
        let encodedSegments: [String] = pathSegments.map { strictPathComponentEncoded($0) }
        let basePath = components.percentEncodedPath.hasSuffix("/")
            ? String(components.percentEncodedPath.dropLast())
            : components.percentEncodedPath
        components.percentEncodedPath = "\(basePath)/\(encodedSegments.joined(separator: "/"))"
        if let queryParameters {
            components.queryItems = queryParameters.map { URLQueryItem(name: $0.key, value: $0.value) }
        }
        guard let url = components.url else {
            throw APIError.invalidURL
        }
        return url
    }

    private enum Constant {
        static let unreservedCharacters: CharacterSet = CharacterSet(
            charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~"
        )
    }
}
