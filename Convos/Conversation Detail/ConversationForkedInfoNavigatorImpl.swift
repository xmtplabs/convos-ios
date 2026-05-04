import Foundation
import NavigationMetrics
import Observation

@MainActor
@Observable
final class ConversationForkedInfoNavigatorImpl: @preconcurrency ConversationForkedInfoNavigator {
    @ObservationIgnored
    private(set) var screenAppearAt: Date?

    init() {}

    func markScreenAppeared() {
        screenAppearAt = Date()
    }

    // MARK: - ConversationForkedInfoNavigator

    func closed(context: ScreenContext) {
        screenAppearAt = nil
    }
}
