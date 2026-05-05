import ConvosMetrics
import Foundation
import Observation

@MainActor
@Observable
final class MembersListNavigatorImpl: @preconcurrency MembersListNavigator {
    var presentingMemberId: String?

    @ObservationIgnored
    private(set) var screenAppearAt: Date?

    init() {}

    func markScreenAppeared() {
        screenAppearAt = Date()
    }

    // MARK: - MembersListNavigator

    func navigateTo(memberProfile args: MemberProfileNavigatorArgs) {
        presentingMemberId = args.memberId
    }

    func closed(context: ScreenContext) {
        screenAppearAt = nil
    }
}
