import ConvosMetrics
import Foundation
import Observation

@MainActor
@Observable
final class SubscriptionSettingsNavigatorImpl: @preconcurrency SubscriptionSettingsNavigator {
    var presentingPaywall: Bool = false

    @ObservationIgnored
    private(set) var screenAppearAt: Date?

    init() {}

    func markScreenAppeared() {
        screenAppearAt = Date()
    }

    // MARK: - SubscriptionSettingsNavigator

    func present(paywall: PaywallNavigatorArgs) {
        presentingPaywall = true
    }

    func closed(context: ScreenContext) {
        screenAppearAt = nil
    }
}
