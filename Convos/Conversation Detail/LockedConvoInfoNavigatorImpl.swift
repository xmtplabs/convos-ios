import ConvosMetrics
import Foundation
import Observation

@MainActor
@Observable
final class LockedConvoInfoNavigatorImpl: @preconcurrency LockedConvoInfoNavigator {
    @ObservationIgnored
    private(set) var screenAppearAt: Date?

    init() {}

    func markScreenAppeared() {
        screenAppearAt = Date()
    }

    // MARK: - LockedConvoInfoNavigator

    func present(lockConfirmation: LockConvoConfirmationNavigatorArgs) {}

    func closed(context: ScreenContext) {
        screenAppearAt = nil
    }
}
