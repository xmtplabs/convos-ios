import ConvosCore
import Foundation

/// Fetches a Space page as its evaluated component tree.
///
/// This talks to the Space origin directly rather than through
/// `ConvosAPIClient`: a Space is served openly, so the request carries no
/// credential, and the URL is the one the worker published into the group's
/// appData rather than a backend route.
enum SpaceDocumentLoader {
    enum LoadError: Error, Equatable {
        /// The Space URL could not be turned into a document URL.
        case invalidURL
        /// The document exists but its queries could not settle right now.
        /// The reason is the server's stable machine-readable one.
        case unavailable(reason: String)
        /// Any other non-success status.
        case status(code: Int)
        /// The body did not decode as a document.
        case malformed
    }

    private struct Failure: Decodable {
        struct Reason: Decodable { let reason: String }
        let error: Reason
    }

    /// Builds the JSON URL for one route under a Space's base URL.
    ///
    /// The base URL carries a path of its own wherever Spaces are served from
    /// the path adapter (`…/__spaces/<routingId>`), so the route is appended to
    /// it rather than replacing it.
    static func documentURL(base: URL, route: String) -> URL? {
        guard var components = URLComponents(url: base, resolvingAgainstBaseURL: false) else {
            return nil
        }
        var basePath = components.path
        while basePath.hasSuffix("/") {
            basePath.removeLast()
        }
        let suffix = route == "/" ? "" : route
        components.path = basePath.isEmpty && suffix.isEmpty ? "/" : basePath + suffix
        components.queryItems = [URLQueryItem(name: "format", value: "json")]
        return components.url
    }

    /// Loads one routed page. `route` is the Space route, `/` for the home page.
    static func load(
        base: URL,
        route: String = "/",
        session: URLSession = .shared
    ) async throws -> SpaceDocument {
        guard let url = documentURL(base: base, route: route) else {
            throw LoadError.invalidURL
        }
        var request = URLRequest(url: url)
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw LoadError.malformed
        }
        guard http.statusCode == 200 else {
            // 503 is the documented answer for a page whose queries could not
            // settle. It is worth keeping distinct: the tab should hold what it
            // already drew rather than treat it as a missing page.
            if http.statusCode == 503,
               let failure = try? JSONDecoder().decode(Failure.self, from: data) {
                throw LoadError.unavailable(reason: failure.error.reason)
            }
            throw LoadError.status(code: http.statusCode)
        }
        do {
            return try JSONDecoder().decode(SpaceDocument.self, from: data)
        } catch {
            Log.warning("Space document did not decode: \(error)")
            throw LoadError.malformed
        }
    }
}
