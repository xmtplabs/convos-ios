@testable import ConvosCore
import Foundation
import Testing

/// Validates the bug fix where `refresh()` used to revert a purchased
/// subscription back to whatever the preset's `subscription()` returned.
struct MockSubscriptionServiceTests {
    @Test func purchase_thenRefresh_keepsPlusAnnual() async throws {
        let service: MockSubscriptionService = MockSubscriptionService(initialPreset: .noSubNoTrial)

        try await service.purchase(productId: SubscriptionProductIDs.plusAnnual)

        #expect(service.currentSubscription?.tier == .plus)
        #expect(service.currentSubscription?.period == .annual)
        #expect(service.currentSubscription?.productId == SubscriptionProductIDs.plusAnnual)

        await service.refresh(force: true)

        #expect(service.currentSubscription?.tier == .plus)
        #expect(service.currentSubscription?.period == .annual)
        #expect(service.currentSubscription?.productId == SubscriptionProductIDs.plusAnnual)
    }

    @Test func purchase_thenRefresh_keepsPlusMonthly() async throws {
        let service: MockSubscriptionService = MockSubscriptionService(initialPreset: .noSubNoTrial)

        try await service.purchase(productId: SubscriptionProductIDs.plusMonthly)

        #expect(service.currentSubscription?.productId == SubscriptionProductIDs.plusMonthly)

        await service.refresh(force: true)

        #expect(service.currentSubscription?.productId == SubscriptionProductIDs.plusMonthly)
    }

    @Test func setPreset_overridesPurchasedSnapshot() async throws {
        let service: MockSubscriptionService = MockSubscriptionService(initialPreset: .noSubNoTrial)

        try await service.purchase(productId: SubscriptionProductIDs.plusMonthly)
        #expect(service.currentSubscription?.tier == .plus)

        service.setPreset(.noSubNoTrial)
        await service.refresh(force: true)

        #expect(service.currentSubscription == nil, "setPreset(.noSubNoTrial) must clear a purchased mock subscription")
    }

    @Test func purchase_unknownProductId_throws() async {
        let service: MockSubscriptionService = MockSubscriptionService(initialPreset: .noSubNoTrial)
        await #expect(throws: SubscriptionServiceError.self) {
            try await service.purchase(productId: "app.convos.subs.does-not-exist")
        }
        #expect(service.currentSubscription == nil)
    }

    @Test func init_seedsCurrentSubscriptionFromPreset() {
        let plus: MockSubscriptionService = MockSubscriptionService(initialPreset: .plusAmple)
        #expect(plus.currentSubscription?.tier == .plus)

        let none: MockSubscriptionService = MockSubscriptionService(initialPreset: .noSubNoTrial)
        #expect(none.currentSubscription == nil)
    }
}
