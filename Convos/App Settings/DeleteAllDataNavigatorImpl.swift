import ConvosMetrics
import Foundation
import Observation

@MainActor
@Observable
final class DeleteAllDataNavigatorImpl: @preconcurrency DeleteAllDataNavigator {
    @ObservationIgnored
    private(set) var screenAppearAt: Date?

    init() {}

    func markScreenAppeared() {
        screenAppearAt = Date()
    }

    // MARK: - DeleteAllDataNavigator

    func closed(context: ScreenContext) {
        screenAppearAt = nil
    }
}
