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

    func authenticateWithSIWE(
        appCheckToken: String,
        signing: BackendAuthSigningContext
    ) async throws -> String {
        "mock-siwe-jwt-token"
    }

    func updateSIWESigningContext(_ context: BackendAuthSigningContext?) {
        // no-op
    }

    func accountAuthCheck(jwt: String?) async throws -> ConvosAPI.AuthCheckResponse {
        .init(success: jwt != nil)
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

    func subscribeToTopics(
        deviceId: String,
        clientId: String,
        topics: [String],
        options: ConvosAPI.SubscribeOptions
    ) async throws -> ConvosAPI.SubscribeResponse {
        // no-op in mock — return a synthetic success so tests don't have to
        // care about cache-write contracts unless they explicitly inject a
        // recording API client.
        return ConvosAPI.SubscribeResponse(
            ok: true,
            remoteApplied: true,
            snapshot: ConvosAPI.SubscribeResponse.Snapshot(
                hash: "mock-hash",
                count: topics.count,
                lastSubscribeAt: ISO8601DateFormatter().string(from: Date())
            ),
            skipped: nil
        )
    }

    func unsubscribeFromTopics(clientId: String, topics: [String]) async throws {
        // no-op in mock
    }

    func debugStatus(
        deviceId: String,
        clientId: String,
        pushTokenSha256: String?,
        pushTokenType: String?,
        apnsEnv: String?
    ) async throws -> ConvosAPI.DebugStatusResponse {
        ConvosAPI.DebugStatusResponse(
            device: .init(exists: false, hasPushToken: false, pushTokenMatches: nil,
                          pushTokenTypeMatches: nil, apnsEnvMatches: nil, disabled: nil,
                          pushFailures: nil, lastSentAt: nil, lastFailureAt: nil, updatedAt: nil),
            client: .init(exists: false, mappedDeviceId: nil, deviceIdMatchesJwt: nil,
                          accountIdMatchesJwt: nil, updatedAt: nil),
            subscriptionSnapshot: .init(exists: false, topicCount: nil, topicHash: nil,
                                        hasKindSummary: false, lastContext: nil, lastSubscribeAt: nil,
                                        lastRemoteApplySucceeded: nil, hasLastRemoteApplyError: false,
                                        pushTokenMatchesAtApply: nil, apnsEnvMatchesAtApply: nil,
                                        isActualRemoteState: false)
        )
    }

    func unregisterInstallation(clientId: String) async throws {
        // no-op in mock
    }

    // MARK: - Asset Renewal

    func renewAssetsBatch(assetKeys: [String]) async throws -> AssetRenewalResult {
        AssetRenewalResult(renewed: assetKeys.count, failed: 0, expiredKeys: [])
    }

    func requestAgentJoin(
        slug: String,
        templateId: String? = nil,
        options: ConvosAPI.AgentJoinOptions? = nil,
        forceErrorCode: Int? = nil
    ) async throws -> ConvosAPI.AgentJoinResponse {
        .init(success: true, joined: true)
    }

    // MARK: - Connections

    func initiateCloudConnection(serviceId: String, redirectUri: String) async throws -> CloudConnectionsAPI.InitiateResponse {
        .init(connectionRequestId: "mock-request-\(UUID().uuidString)", redirectUrl: "https://accounts.google.com/o/oauth2/auth?mock=true")
    }

    func completeCloudConnection(connectionRequestId: String) async throws -> CloudConnectionsAPI.CompleteResponse {
        .init(
            connectionId: "mock-conn-\(UUID().uuidString)",
            serviceId: "googlecalendar",
            serviceName: "Google Calendar",
            composioEntityId: "convos_mock_entity",
            composioConnectionId: "mock_composio_conn",
            status: "active"
        )
    }

    func listCloudConnections() async throws -> [CloudConnectionsAPI.ConnectionResponse] {
        []
    }

    func revokeCloudConnection(connectionId: String) async throws {}

    func getCreditBalance() async throws -> CreditBalance {
        CreditBalance(
            balance: 0,
            monthlyGrant: 0,
            monthlyGrantUsed: 0,
            nextRefreshAt: Date(),
            periodLabel: ""
        )
    }

    func getSubscription() async throws -> UserSubscription? {
        nil
    }

    func verifySubscription(jwsRepresentation: String) async throws -> UserSubscription {
        throw MockAPIError.invalidURL
    }
}
