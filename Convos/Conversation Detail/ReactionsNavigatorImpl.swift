import ConvosMetrics
import Foundation
import Observation

@MainActor
@Observable
final class ReactionsNavigatorImpl: @preconcurrency ReactionsNavigator {
    @ObservationIgnored
    private(set) var screenAppearAt: Date?

    init() {}

    func markScreenAppeared() {
        screenAppearAt = Date()
    }

    // MARK: - ReactionsNavigator

    func closed(context: ScreenContext) {
        screenAppearAt = nil
    }
}
