import Foundation
import NavigationMetrics
import Observation

@MainActor
@Observable
final class AssistantConfirmationNavigatorImpl: @preconcurrency AssistantConfirmationNavigator {
    @ObservationIgnored
    private(set) var screenAppearAt: Date?

    init() {}

    func markScreenAppeared() {
        screenAppearAt = Date()
    }

    // MARK: - AssistantConfirmationNavigator

    func closed(context: ScreenContext) {
        screenAppearAt = nil
    }
}
