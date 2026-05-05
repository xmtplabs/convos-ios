import ConvosMetrics
import Foundation
import Observation

@MainActor
@Observable
final class AssistantSettingsNavigatorImpl: @preconcurrency AssistantSettingsNavigator {
    var presentingInviteCodeEntry: Bool = false

    @ObservationIgnored
    private(set) var screenAppearAt: Date?

    init() {}

    func markScreenAppeared() {
        screenAppearAt = Date()
    }

    // MARK: - AssistantSettingsNavigator

    func present(inviteCodeEntry: InviteCodeEntryNavigatorArgs) {
        presentingInviteCodeEntry = true
    }

    func closed(context: ScreenContext) {
        screenAppearAt = nil
    }
}
