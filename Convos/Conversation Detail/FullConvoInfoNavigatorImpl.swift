import Foundation
import NavigationMetrics
import Observation

@MainActor
@Observable
final class FullConvoInfoNavigatorImpl: @preconcurrency FullConvoInfoNavigator {
    @ObservationIgnored
    private(set) var screenAppearAt: Date?

    init() {}

    func markScreenAppeared() {
        screenAppearAt = Date()
    }

    // MARK: - FullConvoInfoNavigator

    func closed(context: ScreenContext) {
        screenAppearAt = nil
    }
}
