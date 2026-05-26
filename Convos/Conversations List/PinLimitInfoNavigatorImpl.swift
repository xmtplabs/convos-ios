import ConvosMetrics
import Foundation
import Observation

@MainActor
@Observable
final class PinLimitInfoNavigatorImpl: @preconcurrency PinLimitInfoNavigator {
    @ObservationIgnored
    private(set) var screenAppearAt: Date?

    init() {}

    func markScreenAppeared() {
        screenAppearAt = Date()
    }

    // MARK: - PinLimitInfoNavigator

    func closed(context: ScreenContext) {
        screenAppearAt = nil
    }
}
