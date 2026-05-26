import ConvosMetrics
import Foundation
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
