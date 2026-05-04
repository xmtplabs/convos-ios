import Foundation
import NavigationMetrics
import Observation

@MainActor
@Observable
final class AssistantFilesLinksNavigatorImpl: @preconcurrency AssistantFilesLinksNavigator {
    @ObservationIgnored
    private(set) var screenAppearAt: Date?

    init() {}

    func markScreenAppeared() {
        screenAppearAt = Date()
    }

    // MARK: - AssistantFilesLinksNavigator

    func closed(context: ScreenContext) {
        screenAppearAt = nil
    }
}
