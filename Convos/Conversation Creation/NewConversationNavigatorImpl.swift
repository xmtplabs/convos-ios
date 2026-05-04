import Foundation
import NavigationMetrics
import Observation

@MainActor
@Observable
final class NewConversationNavigatorImpl: @preconcurrency NewConversationNavigator {
    @ObservationIgnored
    private(set) var screenAppearAt: Date?

    init() {}

    func markScreenAppeared() {
        screenAppearAt = Date()
    }

    // MARK: - NewConversationNavigator

    func closed(context: ScreenContext) {
        screenAppearAt = nil
    }
}
