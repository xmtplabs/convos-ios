import Foundation
import NavigationMetrics
import Observation

@MainActor
@Observable
final class AssistantInfoNavigatorImpl: @preconcurrency AssistantInfoNavigator {
    @ObservationIgnored
    private(set) var screenAppearAt: Date?

    init() {}

    func markScreenAppeared() {
        screenAppearAt = Date()
    }

    // MARK: - AssistantInfoNavigator

    func closed(context: ScreenContext) {
        screenAppearAt = nil
    }
}
