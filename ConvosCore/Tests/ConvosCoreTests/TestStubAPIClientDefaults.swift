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
}
