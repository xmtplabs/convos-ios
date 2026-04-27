import Foundation

class MockAPIClientFactory: ConvosAPIClientFactoryType {
    static func client(environment: AppEnvironment, overrideJWTToken: String? = nil) -> any ConvosAPIClientProtocol {
        MockAPIClient(overrideJWTToken: overrideJWTToken)
    }
}

enum MockAPIError: Error {
    case invalidURL
}

final class MockAPIClient: ConvosAPIClientProtocol, Sendable {
    let overrideJWTToken: String?

    init(overrideJWTToken: String? = nil) {
        self.overrideJWTToken = overrideJWTToken
    }

    func request(for path: String, method: String, queryParameters: [String: String]?) throws -> URLRequest {
        guard let url = URL(string: "http://example.com") else {
            throw MockAPIError.invalidURL
        }
        return URLRequest(url: url)
    }

    func registerDevice(deviceId: String, pushToken: String?) async throws {
        // Mock implementation - no-op
    }

    func authenticate(appCheckToken: String, retryCount: Int = 0) async throws -> String {
        return "mock-jwt-token"
    }

    func uploadAttachment(
        data: Data,
        filename: String,
        contentType: String,
        acl: String
    ) async throws -> String {
        "https://mock-api.example.com/uploads/\(filename)"
    }

    func uploadAttachmentAndExecute(
        data: Data,
        filename: String,
        afterUpload: @escaping (String) async throws -> Void
    ) async throws -> String {
        let url = "https://mock-api.example.com/uploads/\(filename)"
        try await afterUpload(url)
        return url
    }

    func getPresignedUploadURL(
        filename: String,
        contentType: String
    ) async throws -> (uploadURL: String, assetURL: String) {
        let uploadURL = "https://mock-s3.example.com/upload/\(filename)?presigned=true"
        let assetURL = "https://mock-cdn.example.com/assets/\(filename)"
        return (uploadURL: uploadURL, assetURL: assetURL)
    }

    // MARK: - Notifications mocks

    func subscribeToTopics(deviceId: String, clientId: String, topics: [String]) async throws {
        // no-op in mock
    }

    func unsubscribeFromTopics(clientId: String, topics: [String]) async throws {
        // no-op in mock
    }

    func unregisterInstallation(clientId: String) async throws {
        // no-op in mock
    }

    // MARK: - Asset Renewal

    func renewAssetsBatch(assetKeys: [String]) async throws -> AssetRenewalResult {
        AssetRenewalResult(renewed: assetKeys.count, failed: 0, expiredKeys: [])
    }

    func requestAgentJoin(slug: String, instructions: String, forceErrorCode: Int? = nil) async throws -> ConvosAPI.AgentJoinResponse {
        .init(success: true, joined: true)
    }

    func redeemInviteCode(_ code: String) async throws -> ConvosAPI.InviteCodeStatus {
        .init(code: "MOCKCODE", name: nil, maxRedemptions: 5, redemptionCount: 0, remainingRedemptions: 5)
    }

    func fetchInviteCodeStatus(_ code: String) async throws -> ConvosAPI.InviteCodeStatus {
        .init(code: code.uppercased(), name: nil, maxRedemptions: 5, redemptionCount: 1, remainingRedemptions: 4)
    }

    // MARK: - Connections

    func initiateConnection(serviceId: String, redirectUri: String) async throws -> ConnectionsAPI.InitiateResponse {
        .init(connectionRequestId: "mock-request-\(UUID().uuidString)", redirectUrl: "https://accounts.google.com/o/oauth2/auth?mock=true")
    }

    func completeConnection(connectionRequestId: String) async throws -> ConnectionsAPI.CompleteResponse {
        .init(
            connectionId: "mock-conn-\(UUID().uuidString)",
            serviceId: "googlecalendar",
            serviceName: "Google Calendar",
            composioEntityId: "convos_mock_entity",
            composioConnectionId: "mock_composio_conn",
            status: "active"
        )
    }

    func listConnections() async throws -> [ConnectionsAPI.ConnectionResponse] {
        []
    }

    func revokeConnection(connectionId: String) async throws {}
}
