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

    /// Default for the post-`options:` `requestAgentJoin` signature so
    /// pre-existing test mocks (which still carry the old
    /// `slug:templateId:forceErrorCode:` shape) don't have to re-stub it
    /// every time the protocol gains a parameter. Tests that exercise
    /// `requestAgentJoin` specifically should still override this on
    /// their fixture.
    func requestAgentJoin(
        slug: String?,
        templateId: String?,
        options: ConvosAPI.AgentJoinOptions?,
        forceErrorCode: Int?
    ) async throws -> ConvosAPI.AgentJoinResponse {
        ConvosAPI.AgentJoinResponse(
            success: true,
            joined: true,
            instanceId: "test-instance",
            inboxId: "test-agent-inbox"
        )
    }

    /// Defaults for the direct-add companions so pre-existing stubs don't
    /// re-stub them. Tests that exercise the direct-add flow specifically
    /// should override these on their fixture.
    func confirmAgentJoin(
        instanceId: String,
        conversationId: String
    ) async throws -> ConvosAPI.AgentConfirmJoinResponse {
        ConvosAPI.AgentConfirmJoinResponse(success: true, joinStatus: "starting")
    }

    func getAgentJoinStatus(instanceId: String) async throws -> ConvosAPI.AgentJoinStatusResponse {
        ConvosAPI.AgentJoinStatusResponse(
            success: true,
            instanceId: instanceId,
            joinStatus: "starting",
            joined: false,
            inboxId: "test-agent-inbox"
        )
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
}
