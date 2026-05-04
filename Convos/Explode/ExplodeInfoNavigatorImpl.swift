import Foundation
import NavigationMetrics
import Observation

@MainActor
@Observable
final class ExplodeInfoNavigatorImpl: @preconcurrency ExplodeInfoNavigator {
    @ObservationIgnored
    private(set) var screenAppearAt: Date?

    init() {}

    func markScreenAppeared() {
        screenAppearAt = Date()
    }

    // MARK: - ExplodeInfoNavigator

    func closed(context: ScreenContext) {
        screenAppearAt = nil
    }
}
