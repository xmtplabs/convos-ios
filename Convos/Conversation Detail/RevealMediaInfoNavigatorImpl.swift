import ConvosMetrics
import Foundation
import Observation

@MainActor
@Observable
final class RevealMediaInfoNavigatorImpl: @preconcurrency RevealMediaInfoNavigator {
    @ObservationIgnored
    private(set) var screenAppearAt: Date?

    init() {}

    func markScreenAppeared() {
        screenAppearAt = Date()
    }

    // MARK: - RevealMediaInfoNavigator

    func closed(context: ScreenContext) {
        screenAppearAt = nil
    }
}
