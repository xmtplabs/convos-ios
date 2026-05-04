import Foundation
import NavigationMetrics
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
