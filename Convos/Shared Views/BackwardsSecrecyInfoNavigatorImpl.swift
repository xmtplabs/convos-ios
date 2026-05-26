import ConvosMetrics
import Foundation
import Observation

@MainActor
@Observable
final class BackwardsSecrecyInfoNavigatorImpl: @preconcurrency BackwardsSecrecyInfoNavigator {
    @ObservationIgnored
    private(set) var screenAppearAt: Date?

    init() {}

    func markScreenAppeared() {
        screenAppearAt = Date()
    }

    // MARK: - BackwardsSecrecyInfoNavigator

    func closed(context: ScreenContext) {
        screenAppearAt = nil
    }
}
