import Foundation
import NavigationMetrics
import Observation

@MainActor
@Observable
final class ShareInviteNavigatorImpl: @preconcurrency ShareInviteNavigator {
    @ObservationIgnored
    private(set) var screenAppearAt: Date?

    init() {}

    func markScreenAppeared() {
        screenAppearAt = Date()
    }

    // MARK: - ShareInviteNavigator

    func closed(context: ScreenContext) {
        screenAppearAt = nil
    }
}
