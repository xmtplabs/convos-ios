import Foundation
import NavigationMetrics
import Observation

@MainActor
@Observable
final class MemberProfileNavigatorImpl: @preconcurrency MemberProfileNavigator {
    @ObservationIgnored
    private(set) var screenAppearAt: Date?

    init() {}

    func markScreenAppeared() {
        screenAppearAt = Date()
    }

    // MARK: - MemberProfileNavigator

    func closed(context: ScreenContext) {
        screenAppearAt = nil
    }
}
