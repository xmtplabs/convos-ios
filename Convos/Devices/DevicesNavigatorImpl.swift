import ConvosMetrics
import Foundation
import Observation

@MainActor
@Observable
final class DevicesNavigatorImpl: @preconcurrency DevicesNavigator, NavigatorLifecycle {
    @ObservationIgnored
    private(set) var screenAppearAt: Date?

    func markScreenAppeared() {
        screenAppearAt = Date()
    }

    func closeContext() -> ScreenContext {
        let secs: Float = screenAppearAt.map { Float(Date().timeIntervalSince($0)) } ?? 0
        screenAppearAt = nil
        return ScreenContext(durationSecs: secs)
    }

    func present(pairDevice: PairDeviceNavigatorArgs) {}
    func present(removeDevice: RemoveDeviceNavigatorArgs) {}
    func closed(context: ScreenContext) {}
}
