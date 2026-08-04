import Foundation

// MARK: - Wire models

extension ConvosAPI {
    struct AccountDeletionRequest: Encodable {
        let operationId: String
    }

    /// Success body of `DELETE /v2/accounts/me`. Any 200 is success,
    /// including a replay against an already-deleted account: the echoed
    /// `operationId` is then the stored one and may differ from the one
    /// sent (it disambiguates retries; it is not an access key).
    public struct AccountDeletionResponse: Decodable, Sendable {
        public let status: String
        public let operationId: String
        public let deletedAt: Date?
        /// Published external-purge completion window. The confirmation
        /// copy reads this when present and falls back to 24.
        public let purgeWindowHours: Int?

        public init(status: String, operationId: String, deletedAt: Date?, purgeWindowHours: Int?) {
            self.status = status
            self.operationId = operationId
            self.deletedAt = deletedAt
            self.purgeWindowHours = purgeWindowHours
        }
    }
}

// MARK: - Client

extension ConvosAPIClient {
    /// Dedicated ephemeral session for the deletion call: the request is
    /// built with an explicitly injected JWT and must never share the
    /// authenticated-session machinery (or its 401 re-auth pipeline).
    private static let accountDeletionSession: URLSession = URLSession(configuration: .ephemeral)

    func deleteAccount(operationId: UUID, jwt: String) async throws -> ConvosAPI.AccountDeletionResponse {
        let url = baseURL.appendingPathComponent("v2/accounts/me")
        var request = URLRequest(url: url)
        request.httpMethod = "DELETE"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(jwt, forHTTPHeaderField: "X-Convos-AuthToken")
        let body = ConvosAPI.AccountDeletionRequest(operationId: operationId.uuidString.lowercased())
        request.httpBody = try JSONEncoder().encode(body)

        let (data, response) = try await Self.accountDeletionSession.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw APIError.invalidResponse
        }

        switch httpResponse.statusCode {
        case 200:
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            return try decoder.decode(ConvosAPI.AccountDeletionResponse.self, from: data)
        case 400:
            throw APIError.badRequest(parseErrorMessage(from: data))
        case 401:
            // Invalid or expired token. Never deletion confirmation.
            throw APIError.notAuthenticated
        case 429:
            throw APIError.rateLimitExceeded
        default:
            throw APIError.serverError(parseErrorMessage(from: data))
        }
    }
}
