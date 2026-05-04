import Foundation
import NavigationMetrics
import Observation

@MainActor
@Observable
final class PhotosInfoNavigatorImpl: @preconcurrency PhotosInfoNavigator {
    @ObservationIgnored
    private(set) var screenAppearAt: Date?

    init() {}

    func markScreenAppeared() {
        screenAppearAt = Date()
    }

    // MARK: - PhotosInfoNavigator

    func closed(context: ScreenContext) {
        screenAppearAt = nil
    }
}
