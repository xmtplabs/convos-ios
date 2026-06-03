import ConvosMetrics
import Foundation
import Observation

@MainActor
@Observable
final class AppSettingsNavigatorImpl: @preconcurrency AppSettingsNavigator {
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

    func navigateTo(myInfo: MyInfoNavigatorArgs) {}
    func navigateTo(customize: CustomizeSettingsNavigatorArgs) {}
    func navigateTo(assistants: AssistantSettingsNavigatorArgs) {}
    func navigateTo(connections: ConnectionsNavigatorArgs) {}
    func navigateTo(backupRestore: BackupRestoreNavigatorArgs) {}
    func navigateTo(deleteAllData: DeleteAllDataNavigatorArgs) {}
    func navigateTo(devices: DevicesNavigatorArgs) {}
    func present(paywall: PaywallNavigatorArgs) {}
    func closed(context: ScreenContext) {}
}
