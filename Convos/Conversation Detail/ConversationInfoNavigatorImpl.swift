import ConvosMetrics
import Foundation
import Observation

@MainActor
@Observable
final class ConversationInfoNavigatorImpl: @preconcurrency ConversationInfoNavigator, NavigatorLifecycle {
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

    func navigateTo(edit: ConversationInfoEditNavigatorArgs) {}
    func navigateTo(membersList: MembersListNavigatorArgs) {}
    func navigateTo(filesAndLinks: AgentFilesLinksNavigatorArgs) {}
    func navigateTo(agentTemplateContactCard: AgentTemplateContactCardNavigatorArgs) {}
    func closed(context: ScreenContext) {}
}
