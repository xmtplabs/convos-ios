import Foundation
import NavigationMetrics
import Observation

@MainActor
@Observable
final class ConversationInfoNavigatorImpl: @preconcurrency ConversationInfoNavigator {
    var presentingEditView: Bool = false
    var presentingShareView: Bool = false
    var showingLockedInfo: Bool = false
    var showingFullInfo: Bool = false
    var showingExplodeSheet: Bool = false

    @ObservationIgnored
    private(set) var screenAppearAt: Date?

    init() {}

    func markScreenAppeared() {
        screenAppearAt = Date()
    }

    // MARK: - ConversationInfoNavigator

    func navigateTo(edit: ConversationInfoEditNavigatorArgs) {
        presentingEditView = true
    }

    func navigateTo(membersList: MembersListNavigatorArgs) {}

    func navigateTo(filesAndLinks: AssistantFilesLinksNavigatorArgs) {}

    func closed(context: ScreenContext) {
        screenAppearAt = nil
    }
}
