import Foundation
import NavigationMetrics
import Observation

@MainActor
@Observable
final class MyInfoNavigatorImpl: @preconcurrency MyInfoNavigator {
    var presentingQuicknameRandomizer: Bool = false

    @ObservationIgnored
    private(set) var screenAppearAt: Date?

    init() {}

    func markScreenAppeared() {
        screenAppearAt = Date()
    }

    // MARK: - MyInfoNavigator

    func navigateTo(quicknameRandomizer: QuicknameRandomizerNavigatorArgs) {
        presentingQuicknameRandomizer = true
    }

    func closed(context: ScreenContext) {
        screenAppearAt = nil
    }
}
