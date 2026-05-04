import Foundation
import NavigationMetrics
import Observation

@MainActor
@Observable
final class RequestPushNotificationsNavigatorImpl: @preconcurrency RequestPushNotificationsNavigator {
    @ObservationIgnored
    private(set) var screenAppearAt: Date?

    init() {}

    func markScreenAppeared() {
        screenAppearAt = Date()
    }

    // MARK: - RequestPushNotificationsNavigator

    func closed(context: ScreenContext) {
        screenAppearAt = nil
    }
}
