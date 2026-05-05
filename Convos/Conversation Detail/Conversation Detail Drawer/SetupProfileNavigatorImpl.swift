import ConvosMetrics
import Foundation
import Observation

@MainActor
@Observable
final class SetupProfileNavigatorImpl: @preconcurrency SetupProfileNavigator {
    @ObservationIgnored
    private(set) var screenAppearAt: Date?

    init() {}

    func markScreenAppeared() {
        screenAppearAt = Date()
    }

    // MARK: - SetupProfileNavigator

    func closed(context: ScreenContext) {
        screenAppearAt = nil
    }
}
