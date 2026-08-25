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
    typealias AuthenticatedRequestExecutor = @Sendable (URLRequest) async throws -> (Data, HTTPURLResponse)

    let overrideJWTToken: String?
    private let authenticatedRequestExecutor: AuthenticatedRequestExecutor

    init(
        overrideJWTToken: String? = nil,
        authenticatedRequestExecutor: AuthenticatedRequestExecutor? = nil
    ) {
        self.overrideJWTToken = overrideJWTToken
        self.authenticatedRequestExecutor = authenticatedRequestExecutor ?? Self.defaultAuthenticatedResponse
    }

    func request(for path: String, method: String, queryParameters: [String: String]?) throws -> URLRequest {
        let normalizedPath = path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard var components = URLComponents(string: "https://mock-api.example.com/api/\(normalizedPath)") else {
            throw MockAPIError.invalidURL
        }
        components.queryItems = queryParameters?.sorted { $0.key < $1.key }.map {
            URLQueryItem(name: $0.key, value: $0.value)
        }
        guard let url = components.url else { throw MockAPIError.invalidURL }
        return URLRequest(url: url)
    }

    func authorizedRequest(for endpoint: String, method: String, queryParameters: [String: String]?) async throws -> URLRequest {
        var request = try request(for: endpoint, method: method, queryParameters: queryParameters)
        request.httpMethod = method
        request.setValue(overrideJWTToken ?? "mock-jwt-token", forHTTPHeaderField: "X-Convos-AuthToken")
        return request
    }

    func performAuthenticatedRequest(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        try await authenticatedRequestExecutor(request)
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

    func requestAgentJoin(
        _ joinRequest: ConvosAPI.AgentJoinRequest,
        forceErrorCode: Int? = nil
    ) async throws -> ConvosAPI.AgentJoinResponse {
        .init(success: true, joined: true, instanceId: "mock-instance", inboxId: "mock-agent-inbox")
    }

    func getAgentJoinStatus(instanceId: String, variantId: String?) async throws -> ConvosAPI.AgentJoinStatusResponse {
        // A registered, joined agent — a coherent terminal state (joined ⇒
        // inbox present), not "starting" paired with an inbox, which masks the
        // poll loop and can't be told apart from a real in-flight state.
        .init(
            success: true,
            instanceId: instanceId,
            joinStatus: "joined",
            joined: true,
            inboxId: "mock-agent-inbox"
        )
    }

    func setAgentParticipation(
        conversationId: String,
        mode: String,
        variantId: String?
    ) async throws -> ConvosAPI.AgentParticipationResponse {
        // Echo the request back, matching the real endpoint: the caller renders
        // the level it just set.
        .init(success: true, conversationId: conversationId, mode: mode)
    }

    func getAgentParticipation(
        conversationId: String,
        variantId: String?
    ) async throws -> ConvosAPI.AgentParticipationResponse {
        .init(success: true, conversationId: conversationId, mode: "speak")
    }

    func interruptAgent(
        conversationId: String,
        variantId: String?
    ) async throws -> ConvosAPI.AgentInterruptResponse {
        .init(success: true, conversationId: conversationId, interrupted: 0)
    }

    func shareSpace(
        conversationId: String,
        variantId: String?
    ) async throws -> ConvosAPI.SpaceShareLink {
        .init(
            conversationId: conversationId,
            message: "Import this space using the space-import skill:\nhttps://mock.invalid/space.git",
            expiresAt: "2026-01-01T00:00:00.000Z"
        )
    }

    func getAgentTemplate(idOrUrlSlug: String) async throws -> ConvosAPI.AgentTemplate {
        .init(
            id: UUID().uuidString,
            status: "published",
            publishedUrl: "https://agents.example.com/a/\(idOrUrlSlug)",
            slug: idOrUrlSlug,
            agentName: "Mock Agent",
            description: "A mock agent template for previews and tests.",
            emoji: "🤖",
            avatarUrl: nil
        )
    }

    func getAgentPromptHints() async throws -> [String] {
        [
            "Plan a 3-day trip to Lisbon with a $1000 budget",
            "Draft a weekly meal plan and a grocery list",
            "Summarize long articles into five quick bullet points",
            "Be my daily Spanish conversation partner",
            "Track my workouts and suggest the next session",
        ]
    }

    func getAgentVariants() async throws -> [ConvosAPI.AgentVariant] {
        [
            .init(
                slug: "pr-1234",
                label: "Q+A",
                whatToTest: "Agent asks clarifying questions before building. Check it doesn't over-ask.",
                status: "ready",
                assistantWorkerUrl: "https://ephemeral-pr-1234.convos.fun",
                builderPromptSlug: "qa-flow-v2",
                prUrl: "https://github.com/xmtplabs/convos-assistants/pull/1234",
                branch: "saul/qa-flow",
                commit: "b9adb65"
            ),
            .init(
                slug: "pr-1251",
                label: "Artifact",
                whatToTest: "Replies with an artifact card -- check rendering.",
                status: "building"
            ),
        ]
    }

    private static func defaultAuthenticatedResponse(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        guard let url = request.url else { throw MockAPIError.invalidURL }
        let method = request.httpMethod ?? "GET"
        let responseData: Data
        let statusCode: Int

        if url.path.hasSuffix("/ack"), method == "POST" {
            responseData = Data()
            statusCode = 204
        } else if url.path.hasSuffix("/v2/agent-relay/requests"),
                  URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.contains(where: {
                      $0.name == "status" && $0.value == "completed"
                  }) == true {
            responseData = Data("{\"requests\":[]}".utf8)
            statusCode = 200
        } else if url.path.hasSuffix("/v2/agent-relay/requests"), method == "POST" {
            responseData = Data(
                "{\"requestId\":\"request_mock\",\"returnToken\":\"return_mock\",\"mcpUrl\":\"https://mock-api.example.com/api/v2/agent-relay/mcp\",\"expiresAt\":\"2099-12-31T23:59:59Z\"}".utf8
            )
            statusCode = 201
        } else if url.path.contains("/v2/agent-relay/requests/"), method == "GET" {
            responseData = Data(
                "{\"result\":{\"message\":\"Mock agent response\",\"links\":[],\"completedAt\":\"2026-01-01T00:00:00Z\"}}".utf8
            )
            statusCode = 200
        } else {
            responseData = Data("{}".utf8)
            statusCode = 200
        }

        guard let response = HTTPURLResponse(
            url: url,
            statusCode: statusCode,
            httpVersion: "HTTP/1.1",
            headerFields: ["Content-Type": "application/json"]
        ) else {
            throw APIError.invalidResponse
        }
        return (responseData, response)
    }

    func createAgentTemplateGeneration(
        inputs: ConvosAPI.AgentTemplateGenerationRequest.Inputs,
        source: String,
        clientDeviceId: String?,
        idempotencyKey: String,
        connections: [String],
        variantId: String?
    ) async throws -> ConvosAPI.AgentTemplateGenerationResponse {
        .init(generationId: UUID().uuidString, status: .pending, templateId: nil, error: nil)
    }

    func getAgentTemplateGeneration(
        generationId: String
    ) async throws -> ConvosAPI.AgentTemplateGenerationResponse {
        .init(generationId: generationId, status: .done, templateId: UUID().uuidString, error: nil)
    }

    func getAgentTemplateAttachmentPresignedURL(
        contentType: String,
        contentLength: Int
    ) async throws -> (objectKey: String, uploadURL: String) {
        (objectKey: "build/mock-\(UUID().uuidString)", uploadURL: "https://mock.s3.example.com/upload")
    }

    func uploadAgentTemplateAttachment(
        data: Data,
        contentType: String,
        to uploadURL: String
    ) async throws {}

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

    func getConnectionServices() async throws -> CloudConnectionsAPI.ServicesResponse {
        .init(services: [
            .init(
                id: "googlecalendar",
                composioSlug: "googlecalendar",
                version: 1,
                displayName: .init(values: ["en": "Google Calendar"]),
                bundles: [
                    .init(
                        id: "calendar.events",
                        title: .init(values: ["en": "Events"]),
                        description: .init(values: ["en": "View and edit events on all calendars"]),
                        defaultEnabled: false
                    ),
                    .init(
                        id: "calendar.events.read",
                        title: .init(values: ["en": "View events"]),
                        description: .init(values: ["en": "View events on all calendars"]),
                        defaultEnabled: false
                    ),
                ]
            ),
        ])
    }

    func createConnectionGrant(
        ownerInboxId: String,
        granteeInboxId: String,
        conversationId: String,
        toolkit: String,
        bundleIds: [String]?,
        serviceVersion: Int?
    ) async throws -> CloudConnectionsAPI.CreateGrantResponse {
        .init(id: "mock-grant-\(UUID().uuidString)")
    }

    func revokeConnectionGrant(id: String) async throws {}

    func revokeConnectionGrantByNaturalKey(
        toolkit: String,
        conversationId: String?,
        granteeInboxId: String?
    ) async throws -> Int {
        0
    }

    // MARK: - Abilities (V2)

    func getAbilities() async throws -> AbilitiesAPI.CatalogResponse {
        try AbilitiesAPI.CatalogResponse(
            catalogVersion: 7,
            abilities: MockAbilitiesService.standardCatalog()
        )
    }

    func createAbilityEntitlement(abilityId: String, redirectUri: String?) async throws -> AbilitiesAPI.EntitlementInitiationResponse {
        try AbilitiesAPI.EntitlementInitiationResponse(
            status: .pendingAuth,
            redirectUrl: "https://mock.convos.org/oauth/\(abilityId)",
            connectionRequestId: "mock-connection-request-\(abilityId)"
        )
    }

    @discardableResult
    func completeAbilityEntitlement(abilityId: String, connectionRequestId: String) async throws -> AbilitiesAPI.EntitlementCompleteResponse {
        AbilitiesAPI.EntitlementCompleteResponse()
    }

    func revokeAbilityEntitlement(abilityId: String) async throws {}

    func getConversationAbilities(conversationId: String) async throws -> AbilitiesAPI.ConversationAbilitiesResponse {
        AbilitiesAPI.ConversationAbilitiesResponse(abilities: [])
    }

    @discardableResult
    func putConversationAbility(
        conversationId: String,
        abilityId: String,
        agentInboxId: String,
        bundleIds: [String],
        extendedByInboxId: String?
    ) async throws -> AbilitiesAPI.ConversationAbilityEntry {
        AbilitiesAPI.ConversationAbilityEntry(
            abilityId: abilityId,
            conversationId: conversationId,
            agentInboxId: agentInboxId,
            bundleIds: bundleIds,
            extendedByInboxId: extendedByInboxId,
            extendedByMe: true,
            status: .active,
            createdAt: Date(),
            updatedAt: Date()
        )
    }

    func deleteConversationAbility(conversationId: String, abilityId: String, agentInboxId: String) async throws {}

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
