import ConvosMetrics
import Foundation
import Observation

@MainActor
@Observable
final class ProcessingPowerInfoNavigatorImpl: @preconcurrency ProcessingPowerInfoNavigator {
    @ObservationIgnored
    private(set) var screenAppearAt: Date?

    init() {}

    func markScreenAppeared() {
        screenAppearAt = Date()
    }

    // MARK: - ProcessingPowerInfoNavigator

    func closed(context: ScreenContext) {
        screenAppearAt = nil
    }
}
