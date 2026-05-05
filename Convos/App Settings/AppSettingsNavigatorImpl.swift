import ConvosMetrics
import Foundation
import Observation

@MainActor
@Observable
final class AppSettingsNavigatorImpl: @preconcurrency AppSettingsNavigator {
    var presentingDeleteAllDataConfirmation: Bool = false

    @ObservationIgnored
    private(set) var screenAppearAt: Date?

    init() {}

    func markScreenAppeared() {
        screenAppearAt = Date()
    }

    // MARK: - AppSettingsNavigator

    func navigateTo(myInfo: MyInfoNavigatorArgs) {}

    func navigateTo(customize: CustomizeSettingsNavigatorArgs) {}

    func navigateTo(assistants: AssistantSettingsNavigatorArgs) {}

    func navigateTo(connections: ConnectionsNavigatorArgs) {}

    func navigateTo(backupRestore: BackupRestoreNavigatorArgs) {}

    func navigateTo(deleteAllData: DeleteAllDataNavigatorArgs) {
        presentingDeleteAllDataConfirmation = true
    }

    func closed(context: ScreenContext) {
        screenAppearAt = nil
    }
}
