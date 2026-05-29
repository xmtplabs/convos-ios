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
        slug: String,
        templateId: String?,
        options: ConvosAPI.AgentJoinOptions?,
        forceErrorCode: Int?
    ) async throws -> ConvosAPI.AgentJoinResponse {
        ConvosAPI.AgentJoinResponse(success: true, joined: true)
    }

    /// Default for the publish-on-share PATCH used by the agent-template
    /// contact card. Returns a synthetic "published" template so fixtures
    /// don't have to re-stub it. Tests that exercise this specifically
    /// should override on their fixture.
    func publishAgentTemplate(id: String) async throws -> ConvosAPI.AgentTemplate {
        ConvosAPI.AgentTemplate(
            id: id,
            status: "published",
            publishedUrl: "https://agents.example.com/test.\(id.prefix(5))"
        )
    }

    /// Default for the agent-template fetch backing the contacts-list
    /// canonical-identity cache. Stubs that don't exercise template fetching
    /// inherit this; tests that do should override it on their fixture.
    func fetchAgentTemplate(templateId: String) async throws -> ConvosAPI.AgentTemplateResponse {
        ConvosAPI.AgentTemplateResponse(
            id: templateId,
            agentName: nil,
            emoji: nil,
            avatarUrl: nil,
            description: nil,
            publishedUrl: nil,
            status: nil
        )
    }
}
