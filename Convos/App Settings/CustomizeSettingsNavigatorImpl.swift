import ConvosMetrics
import Foundation
import Observation

@MainActor
@Observable
final class CustomizeSettingsNavigatorImpl: @preconcurrency CustomizeSettingsNavigator {
    @ObservationIgnored
    private(set) var screenAppearAt: Date?

    init() {}

    func markScreenAppeared() {
        screenAppearAt = Date()
    }

    // MARK: - CustomizeSettingsNavigator

    func closed(context: ScreenContext) {
        screenAppearAt = nil
    }
}
