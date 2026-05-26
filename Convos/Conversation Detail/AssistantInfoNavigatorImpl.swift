import ConvosMetrics
import Foundation
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
