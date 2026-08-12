import Foundation

extension ConvosAPIClient {
    /// Percent-encodes one path segment with the RFC 3986 unreserved set
    /// only, so opaque identifiers stay within a single path component.
    static func strictPathComponentEncoded(_ raw: String) -> String {
        raw.addingPercentEncoding(withAllowedCharacters: Constant.unreservedCharacters) ?? raw
    }

    /// Builds an endpoint URL by setting the percent-encoded path directly.
    /// Appending pre-encoded path components would encode `%` a second time.
    static func endpointURL(
        baseURL: URL,
        pathSegments: [String],
        queryParameters: [String: String]?
    ) throws -> URL {
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

    func endpointRequest(
        pathSegments: [String],
        method: String,
        queryParameters: [String: String]? = nil
    ) throws -> URLRequest {
        let url = try Self.endpointURL(
            baseURL: baseURL,
            pathSegments: pathSegments,
            queryParameters: queryParameters
        )
        var request = URLRequest(url: url)
        request.httpMethod = method
        return attachingAuthHeader(to: request)
    }

    private enum Constant {
        static let unreservedCharacters: CharacterSet = CharacterSet(
            charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~"
        )
    }
}
