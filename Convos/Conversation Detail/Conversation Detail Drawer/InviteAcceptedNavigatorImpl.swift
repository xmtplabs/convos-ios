import ConvosMetrics
import Foundation
import Observation

@MainActor
@Observable
final class InviteAcceptedNavigatorImpl: @preconcurrency InviteAcceptedNavigator {
    @ObservationIgnored
    private(set) var screenAppearAt: Date?

    init() {}

    func markScreenAppeared() {
        screenAppearAt = Date()
    }

    // MARK: - InviteAcceptedNavigator

    func closed(context: ScreenContext) {
        screenAppearAt = nil
    }
}
