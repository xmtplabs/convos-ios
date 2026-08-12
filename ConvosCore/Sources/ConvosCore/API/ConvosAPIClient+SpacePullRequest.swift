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
                throw spacePullRequestProposalEndpointError(statusCode: response.statusCode, data: data)
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
        var request = try authenticatedRequest(
            for: "v2/conversations/\(participationPathComponent(conversationId))/debug/space-upstream",
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

    private func spacePullRequestProposalEndpointError(statusCode: Int, data: Data) -> Error {
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
