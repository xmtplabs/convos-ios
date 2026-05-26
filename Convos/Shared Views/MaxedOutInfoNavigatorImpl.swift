import ConvosMetrics
import Foundation
import Observation

@MainActor
@Observable
final class MaxedOutInfoNavigatorImpl: @preconcurrency MaxedOutInfoNavigator {
    @ObservationIgnored
    private(set) var screenAppearAt: Date?

    init() {}

    func markScreenAppeared() {
        screenAppearAt = Date()
    }

    // MARK: - MaxedOutInfoNavigator

    func closed(context: ScreenContext) {
        screenAppearAt = nil
    }
}
