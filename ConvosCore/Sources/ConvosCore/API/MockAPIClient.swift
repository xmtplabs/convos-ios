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
        slug: String? = nil,
        conversationId: String? = nil,
        templateId: String? = nil,
        options: ConvosAPI.AgentJoinOptions? = nil,
        timezone: String? = nil,
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

    func getFeaturedAgentTemplates(limit: Int, cursor: String?) async throws -> ConvosAPI.AgentTemplatesPage {
        let templates: [ConvosAPI.AgentTemplate] = [
            .init(id: "tmpl-trip", status: "published", publishedUrl: nil, slug: "trip", agentName: "Trip", description: "Travel agent", emoji: "🧳", avatarUrl: nil),
            .init(id: "tmpl-champ", status: "published", publishedUrl: nil, slug: "champ", agentName: "Champ", description: "Team manager", emoji: "🏆", avatarUrl: nil),
            .init(id: "tmpl-chef", status: "published", publishedUrl: nil, slug: "chef", agentName: "Chef", description: "Meal and nutrition partner", emoji: "🍽️", avatarUrl: nil),
        ]
        return .init(data: templates, hasMore: false, nextCursor: nil)
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

    func createAgentTemplateGeneration(
        text: String,
        source: String,
        clientDeviceId: String?,
        idempotencyKey: String,
        attachments: [ConvosAPI.AttachmentRef],
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
