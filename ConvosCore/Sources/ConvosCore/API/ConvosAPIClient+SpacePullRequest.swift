import Foundation

extension ConvosAPIClient {
    func proposePullRequestFromSpace(
        conversationId: String,
        variantId: String?
    ) async throws -> ConvosAPI.SpacePullRequestProposalOutcome {
        let request = try spacePullRequestProposalRequest(
            conversationId: conversationId,
            variantId: variantId
        )
        do {
            let (data, response) = try await performAuthenticatedRequest(request)
            guard (200...299).contains(response.statusCode) else {
                throw spacePullRequestProposalEndpointError(
                    statusCode: response.statusCode,
                    data: data,
                    path: request.url?.path(percentEncoded: false)
                )
            }
            return try Self.decodeSpacePullRequestProposalOutcome(data)
        } catch let error as URLError where error.code == .timedOut {
            throw ConvosAPI.SpacePullRequestProposalError.timeout
        }
    }

    func spacePullRequestProposalRequest(
        conversationId: String,
        variantId: String?
    ) throws -> URLRequest {
        var request = try endpointRequest(
            pathSegments: ["v2", "conversations", conversationId, "debug", "space-upstream"],
            method: "POST",
            queryParameters: prodSafeVariantId(variantId).map { ["variantId": $0] }
        )
        request.timeoutInterval = 55
        return request
    }

    static func decodeSpacePullRequestProposalOutcome(_ data: Data) throws -> ConvosAPI.SpacePullRequestProposalOutcome {
        try JSONDecoder().decode(ConvosAPI.SpacePullRequestProposalOutcome.self, from: data)
    }

    static func decodeSpacePullRequestProposalError(_ data: Data) -> ConvosAPI.SpacePullRequestProposalError? {
        ConvosAPI.SpacePullRequestProposalError(body: data)
    }

    private func spacePullRequestProposalEndpointError(statusCode: Int, data: Data, path: String?) -> Error {
        let bodyLimit = 512
        let body = String(bytes: data.prefix(bodyLimit), encoding: .utf8) ?? "non-UTF-8 body"
        let truncated = data.count > bodyLimit ? "…" : ""
        Log.error("\(path ?? "space pull request endpoint") failed [\(statusCode)]: \(body)\(truncated)")
        if let typedError = Self.decodeSpacePullRequestProposalError(data) {
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
