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

    /// Default for the Stack 2 T12 debug-status endpoint so existing test
    /// fixtures don't need to re-stub it. Tests that exercise the debug
    /// screen specifically should override on their fixture.
    func debugStatus(
        deviceId: String,
        clientId: String,
        pushTokenSha256: String?,
        pushTokenType: String?,
        apnsEnv: String?
    ) async throws -> ConvosAPI.DebugStatusResponse {
        ConvosAPI.DebugStatusResponse(
            device: .init(
                exists: false, hasPushToken: false, pushTokenMatches: nil,
                pushTokenTypeMatches: nil, apnsEnvMatches: nil, disabled: nil,
                pushFailures: nil, lastSentAt: nil, lastFailureAt: nil, updatedAt: nil
            ),
            client: .init(
                exists: false, mappedDeviceId: nil, deviceIdMatchesJwt: nil,
                accountIdMatchesJwt: nil, updatedAt: nil
            ),
            subscriptionSnapshot: .init(
                exists: false, topicCount: nil, topicHash: nil, kindSummary: nil,
                lastContext: nil, lastSubscribeAt: nil, lastRemoteApplySucceeded: nil,
                lastRemoteApplyError: nil, pushTokenMatchesAtApply: nil,
                apnsEnvMatchesAtApply: nil, isActualRemoteState: false
            )
        )
    }
}
