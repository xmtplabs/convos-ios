import Foundation
import NavigationMetrics
import Observation

@MainActor
@Observable
final class ConversationInfoEditNavigatorImpl: @preconcurrency ConversationInfoEditNavigator {
    @ObservationIgnored
    private(set) var screenAppearAt: Date?

    init() {}

    func markScreenAppeared() {
        screenAppearAt = Date()
    }

    // MARK: - ConversationInfoEditNavigator

    func closed(context: ScreenContext) {
        screenAppearAt = nil
    }
}
