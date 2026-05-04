import Foundation
import NavigationMetrics
import Observation

@MainActor
@Observable
final class ExplodedInviteInfoNavigatorImpl: @preconcurrency ExplodedInviteInfoNavigator {
    @ObservationIgnored
    private(set) var screenAppearAt: Date?

    init() {}

    func markScreenAppeared() {
        screenAppearAt = Date()
    }

    // MARK: - ExplodedInviteInfoNavigator

    func closed(context: ScreenContext) {
        screenAppearAt = nil
    }
}
