@testable import ConvosCore
import Foundation
import Testing

/// Validates the bug fix where `refresh()` used to revert a purchased
/// subscription back to whatever the preset's `subscription()` returned.
struct MockSubscriptionServiceTests {
    @Test func purchase_thenRefresh_keepsBuilderAnnual() async throws {
        let service: MockSubscriptionService = MockSubscriptionService(initialPreset: .noSubNoTrial)

        try await service.purchase(productId: SubscriptionProductIDs.builderAnnual)

        #expect(service.currentSubscription?.tier == .builder)
        #expect(service.currentSubscription?.period == .annual)
        #expect(service.currentSubscription?.productId == SubscriptionProductIDs.builderAnnual)

        await service.refresh(force: true)

        // The bug was: refresh re-publishes preset.subscription(), which for
        // .noSubNoTrial is nil. Without the snapshot persistence fix, the
        // refresh would silently revert the purchase.
        #expect(service.currentSubscription?.tier == .builder)
        #expect(service.currentSubscription?.period == .annual)
        #expect(service.currentSubscription?.productId == SubscriptionProductIDs.builderAnnual)
    }

    @Test func purchase_thenRefresh_keepsProMonthly() async throws {
        let service: MockSubscriptionService = MockSubscriptionService(initialPreset: .noSubNoTrial)

        try await service.purchase(productId: SubscriptionProductIDs.proMonthly)

        #expect(service.currentSubscription?.tier == .pro)
        #expect(service.currentSubscription?.period == .monthly)

        await service.refresh(force: true)

        // Macroscope's narrow fix (currentPreset = .builderAmple) would have
        // collapsed Pro into Builder here — that's why we persist a full
        // UserSubscription snapshot instead.
        #expect(service.currentSubscription?.tier == .pro)
        #expect(service.currentSubscription?.period == .monthly)
        #expect(service.currentSubscription?.productId == SubscriptionProductIDs.proMonthly)
    }

    @Test func purchase_thenRefresh_keepsBuilderMonthly() async throws {
        let service: MockSubscriptionService = MockSubscriptionService(initialPreset: .noSubNoTrial)

        try await service.purchase(productId: SubscriptionProductIDs.builderMonthly)

        #expect(service.currentSubscription?.productId == SubscriptionProductIDs.builderMonthly)

        await service.refresh(force: true)

        #expect(service.currentSubscription?.productId == SubscriptionProductIDs.builderMonthly)
    }

    @Test func setPreset_overridesPurchasedSnapshot() async throws {
        // Debug-menu state preset picker still needs to win — operator-driven
        // resets should clear a purchased mock subscription.
        let service: MockSubscriptionService = MockSubscriptionService(initialPreset: .noSubNoTrial)

        try await service.purchase(productId: SubscriptionProductIDs.proMonthly)
        #expect(service.currentSubscription?.tier == .pro)

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
        let builder: MockSubscriptionService = MockSubscriptionService(initialPreset: .builderAmple)
        #expect(builder.currentSubscription?.tier == .builder)

        let none: MockSubscriptionService = MockSubscriptionService(initialPreset: .noSubNoTrial)
        #expect(none.currentSubscription == nil)
    }
}
