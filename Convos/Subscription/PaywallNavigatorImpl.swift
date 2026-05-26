import ConvosMetrics
import Foundation
import Observation

@MainActor
@Observable
final class PaywallNavigatorImpl: @preconcurrency PaywallNavigator {
    @ObservationIgnored
    private(set) var screenAppearAt: Date?

    init() {}

    func markScreenAppeared() {
        screenAppearAt = Date()
    }

    // MARK: - PaywallNavigator

    func closed(context: ScreenContext) {
        screenAppearAt = nil
    }
}
