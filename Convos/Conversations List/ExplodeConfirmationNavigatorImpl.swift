import ConvosMetrics
import Foundation
import Observation

@MainActor
@Observable
final class ExplodeConfirmationNavigatorImpl: @preconcurrency ExplodeConfirmationNavigator {
    @ObservationIgnored
    private(set) var screenAppearAt: Date?

    init() {}

    func markScreenAppeared() {
        screenAppearAt = Date()
    }

    // MARK: - ExplodeConfirmationNavigator

    func closed(context: ScreenContext) {
        screenAppearAt = nil
    }
}
