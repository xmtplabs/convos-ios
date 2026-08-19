import Foundation

extension ConvosAPIClient {
    func shareSpace(
        conversationId: String,
        variantId: String?
    ) async throws -> ConvosAPI.SpaceShareLink {
        let request = try spaceShareRequest(
            conversationId: conversationId,
            variantId: variantId
        )
        do {
            let (data, response) = try await performAuthenticatedRequest(request)
            guard (200...299).contains(response.statusCode) else {
                throw spaceShareEndpointError(
                    statusCode: response.statusCode,
                    data: data,
                    path: request.url?.path(percentEncoded: false)
                )
            }
            return try Self.decodeSpaceShareLink(data)
        } catch let error as URLError where error.code == .timedOut {
            throw ConvosAPI.SpaceShareError.timeout
        }
    }

    func spaceShareRequest(
        conversationId: String,
        variantId: String?
    ) throws -> URLRequest {
        // The strict per-segment URL builder, for the same reason the
        // abilities routes need it — an opaque conversation id must stay
        // one path component.
        let url = try Self.endpointURL(
            baseURL: baseURL,
            pathSegments: ["v2", "conversations", conversationId, "debug", "space-share"],
            queryParameters: prodSafeVariantId(variantId).map { ["variantId": $0] }
        )
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 30
        return attachingAuthHeader(to: request)
    }

    static func decodeSpaceShareLink(_ data: Data) throws -> ConvosAPI.SpaceShareLink {
        try JSONDecoder().decode(ConvosAPI.SpaceShareLink.self, from: data)
    }

    static func decodeSpaceShareError(_ data: Data) -> ConvosAPI.SpaceShareError? {
        ConvosAPI.SpaceShareError(body: data)
    }

    /// Error bodies are loggable; the success body is not — it carries the
    /// live share credential, so it must never reach this path.
    private func spaceShareEndpointError(statusCode: Int, data: Data, path: String?) -> Error {
        let bodyLimit = 512
        let body = String(bytes: data.prefix(bodyLimit), encoding: .utf8) ?? "non-UTF-8 body"
        let truncated = data.count > bodyLimit ? "…" : ""
        Log.error("\(path ?? "space share endpoint") failed [\(statusCode)]: \(body)\(truncated)")
        if let typedError = Self.decodeSpaceShareError(data) {
            return typedError
        }
        switch statusCode {
        case 400:
            return APIError.badRequest(parseErrorMessage(from: data))
        case 403:
            return APIError.forbidden
        case 404:
            return APIError.notFound
        case 429:
            return APIError.rateLimitExceeded
        default:
            return APIError.serverError(parseErrorMessage(from: data))
        }
    }
}
