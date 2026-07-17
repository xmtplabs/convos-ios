@testable import ConvosCore
import Foundation

/// Default no-op implementations of the IAP-credits methods added to
/// `ConvosAPIClientProtocol` so test fixtures that predate that protocol
/// addition (RecordingPushAPIClient, ThrowingPushAPIClient, StubAPIClient,
/// TestableMockAPIClient, ConfigurableMockAPIClient, ThrowawayPushAPIClient,
/// and the reconciliation-test variant) don't each have to re-stub them.
///
/// Lives only in the test target; the main library's `MockAPIClient` provides
/// its own implementations and is unaffected. Tests that specifically exercise
/// these methods should override them on their stub or use a dedicated fixture.
extension ConvosAPIClientProtocol {
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
        throw CancellationError()
    }

    /// Default for the request-struct `requestAgentJoin` signature so
    /// pre-existing test mocks (which still carry the old
    /// `slug:templateId:forceErrorCode:` shape) don't have to re-stub it
    /// every time the request body gains a field. Tests that exercise
    /// `requestAgentJoin` specifically should still override this on
    /// their fixture.
    func requestAgentJoin(
        _ joinRequest: ConvosAPI.AgentJoinRequest,
        forceErrorCode: Int?
    ) async throws -> ConvosAPI.AgentJoinResponse {
        ConvosAPI.AgentJoinResponse(
            success: true,
            joined: true,
            instanceId: "test-instance",
            inboxId: "test-agent-inbox"
        )
    }

    /// Default for the direct-add status poll so pre-existing stubs don't
    /// re-stub it. A coherent terminal state — joined ⇒ inbox present — so
    /// unrelated tests don't iterate the poll loop. Tests that exercise the
    /// poll specifically program their own status sequence (see
    /// DirectAddProvisionPollTests).
    func getAgentJoinStatus(instanceId: String, variantId: String?) async throws -> ConvosAPI.AgentJoinStatusResponse {
        ConvosAPI.AgentJoinStatusResponse(
            success: true,
            instanceId: instanceId,
            joinStatus: "joined",
            joined: true,
            inboxId: "test-agent-inbox"
        )
    }

    /// Default for the dev-only variant registry so stubs that don't exercise
    /// the picker don't have to re-stub it. Empty == no variants registered.
    func getAgentVariants() async throws -> [ConvosAPI.AgentVariant] {
        []
    }

    /// Default for the public agent-template detail fetch used by the
    /// agent-share card/chip resolver. Tests that exercise it specifically
    /// should override on their fixture.
    func getAgentTemplate(idOrUrlSlug: String) async throws -> ConvosAPI.AgentTemplate {
        ConvosAPI.AgentTemplate(
            id: UUID().uuidString,
            status: "published",
            publishedUrl: "https://agents.example.com/a/\(idOrUrlSlug)",
            slug: idOrUrlSlug,
            agentName: "Test Agent",
            description: "A test agent template.",
            emoji: "🤖",
            avatarUrl: nil
        )
    }

    /// Default for the featured agent-templates list backing the contacts
    /// picker's suggested section. Tests that exercise it specifically should
    /// override on their fixture.
    func getFeaturedAgentTemplates(limit: Int, cursor: String?) async throws -> ConvosAPI.AgentTemplatesPage {
        ConvosAPI.AgentTemplatesPage(data: [], hasMore: false, nextCursor: nil)
    }

    /// Default for the agent prompt-hints list backing the builder's dice
    /// control. Tests that exercise it specifically should override on their
    /// fixture.
    func getAgentPromptHints() async throws -> [String] {
        []
    }

    /// Defaults for the backend connection-grant push so pre-existing fixtures
    /// don't have to re-stub them. Tests that exercise the push specifically
    /// should override on their fixture.
    func getConnectionServices() async throws -> CloudConnectionsAPI.ServicesResponse {
        CloudConnectionsAPI.ServicesResponse(services: [])
    }

    func createConnectionGrant(
        ownerInboxId: String,
        granteeInboxId: String,
        conversationId: String,
        toolkit: String,
        bundleIds: [String]?,
        serviceVersion: Int?
    ) async throws -> CloudConnectionsAPI.CreateGrantResponse {
        CloudConnectionsAPI.CreateGrantResponse(id: "test-grant-\(UUID().uuidString)")
    }

    func revokeConnectionGrant(id: String) async throws {}

    func revokeConnectionGrantByNaturalKey(
        toolkit: String,
        conversationId: String?,
        granteeInboxId: String?
    ) async throws -> Int {
        0
    }
}

/// Open, fully-conforming `ConvosAPIClientProtocol` base for test fixtures that
/// only care about one or two methods. Every requirement throws / returns a
/// trivial value; subclasses override just what they exercise. Spares each new
/// stub from re-declaring the whole (large) protocol surface.
class TestStubAPIClient: ConvosAPIClientProtocol, @unchecked Sendable {
    func request(for path: String, method: String, queryParameters: [String: String]?) throws -> URLRequest {
        URLRequest(url: URL(string: "https://example.com/\(path)") ?? URL(string: "https://example.com")!)
    }
    func registerDevice(deviceId: String, pushToken: String?) async throws {}
    func authenticate(appCheckToken: String, retryCount: Int) async throws -> String { "" }
    func authenticateWithSIWE(appCheckToken: String, signing: BackendAuthSigningContext) async throws -> String { "" }
    func updateSIWESigningContext(_ context: BackendAuthSigningContext?) {}
    func accountAuthCheck(jwt: String?) async throws -> ConvosAPI.AuthCheckResponse {
        throw CancellationError()
    }
    func uploadAttachment(data: Data, filename: String, contentType: String, acl: String) async throws -> String { "" }
    func uploadAttachmentAndExecute(data: Data, filename: String, afterUpload: @escaping (String) async throws -> Void) async throws -> String { "" }
    func getPresignedUploadURL(filename: String, contentType: String) async throws -> (uploadURL: String, assetURL: String) {
        ("", "")
    }
    func subscribeToTopics(deviceId: String, clientId: String, topics: [String]) async throws {}
    func unsubscribeFromTopics(clientId: String, topics: [String]) async throws {}
    func unregisterInstallation(clientId: String) async throws {}
    func renewAssetsBatch(assetKeys: [String]) async throws -> AssetRenewalResult {
        AssetRenewalResult(renewed: 0, failed: 0, expiredKeys: [])
    }
    func initiateCloudConnection(serviceId: String, redirectUri: String) async throws -> CloudConnectionsAPI.InitiateResponse {
        throw CancellationError()
    }
    func completeCloudConnection(connectionRequestId: String) async throws -> CloudConnectionsAPI.CompleteResponse {
        throw CancellationError()
    }
    func listCloudConnections() async throws -> [CloudConnectionsAPI.ConnectionResponse] { [] }
    func revokeCloudConnection(connectionId: String) async throws {}

    /// Declared on the base (not just the protocol-extension default) so
    /// subclasses can `override` it.
    func getAgentTemplate(idOrUrlSlug: String) async throws -> ConvosAPI.AgentTemplate {
        ConvosAPI.AgentTemplate(id: UUID().uuidString, status: "published", publishedUrl: nil)
    }

    /// Declared on the base (not just the protocol-extension default) so
    /// subclasses can `override` them.
    func getConnectionServices() async throws -> CloudConnectionsAPI.ServicesResponse {
        CloudConnectionsAPI.ServicesResponse(services: [])
    }

    func createConnectionGrant(
        ownerInboxId: String,
        granteeInboxId: String,
        conversationId: String,
        toolkit: String,
        bundleIds: [String]?,
        serviceVersion: Int?
    ) async throws -> CloudConnectionsAPI.CreateGrantResponse {
        CloudConnectionsAPI.CreateGrantResponse(id: "test-grant-\(UUID().uuidString)")
    }

    func revokeConnectionGrant(id: String) async throws {}

    func revokeConnectionGrantByNaturalKey(
        toolkit: String,
        conversationId: String?,
        granteeInboxId: String?
    ) async throws -> Int {
        0
    }

    /// Declared on the base class (not just the protocol-extension default) so
    /// the direct agent-builder repository's fixtures can `override` it.
    func requestAgentJoin(
        _ joinRequest: ConvosAPI.AgentJoinRequest,
        forceErrorCode: Int?
    ) async throws -> ConvosAPI.AgentJoinResponse {
        ConvosAPI.AgentJoinResponse(
            success: true,
            joined: true,
            instanceId: "test-instance",
            inboxId: "test-agent-inbox"
        )
    }

    func createAgentTemplateGeneration(
        inputs: ConvosAPI.AgentTemplateGenerationRequest.Inputs,
        source: String,
        clientDeviceId: String?,
        idempotencyKey: String,
        connections: [String],
        variantId: String?
    ) async throws -> ConvosAPI.AgentTemplateGenerationResponse {
        ConvosAPI.AgentTemplateGenerationResponse(
            generationId: UUID().uuidString,
            status: .pending,
            templateId: nil,
            error: nil
        )
    }

    func getAgentTemplateGeneration(
        generationId: String
    ) async throws -> ConvosAPI.AgentTemplateGenerationResponse {
        ConvosAPI.AgentTemplateGenerationResponse(
            generationId: generationId,
            status: .done,
            templateId: UUID().uuidString,
            error: nil
        )
    }

    // Declared on the base (not left to the protocol-extension default) so
    // subclasses can `override` them to simulate attachment-upload failures.
    func getAgentTemplateAttachmentPresignedURL(
        contentType: String,
        contentLength: Int
    ) async throws -> (objectKey: String, uploadURL: String) {
        (objectKey: "build/test-\(UUID().uuidString)", uploadURL: "https://test.example.com/upload")
    }

    func uploadAgentTemplateAttachment(
        data: Data,
        contentType: String,
        to uploadURL: String
    ) async throws {}
}
