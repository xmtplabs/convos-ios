import Foundation
import NavigationMetrics
import Observation

@MainActor
@Observable
final class ConnectionGrantNavigatorImpl: @preconcurrency ConnectionGrantNavigator {
    @ObservationIgnored
    private(set) var screenAppearAt: Date?

    init() {}

    func markScreenAppeared() {
        screenAppearAt = Date()
    }

    // MARK: - ConnectionGrantNavigator

    func closed(context: ScreenContext) {
        screenAppearAt = nil
    }
}
