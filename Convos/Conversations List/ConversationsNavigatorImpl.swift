import ConvosMetrics
import Foundation
import Observation

@MainActor
@Observable
final class ConversationsNavigatorImpl: @preconcurrency ConversationsNavigator, NavigatorLifecycle {
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

    func navigateTo(conversation: ConversationNavigatorArgs) {}
    func present(appSettings: AppSettingsNavigatorArgs) {}
    func present(newConversation: NewConversationNavigatorArgs) {}
    func present(explodeConfirmation: ExplodeConfirmationNavigatorArgs) {}
    func present(connectionGrant: ConnectionGrantNavigatorArgs) {}
    func present(explodeInfo: ExplodeInfoNavigatorArgs) {}
    func present(pinLimitInfo: PinLimitInfoNavigatorArgs) {}
    func present(contactCard: ContactCardNavigatorArgs) {}
    func present(agentBuilder: AgentBuilderNavigatorArgs) {}
    func closed(context: ScreenContext) {}
}
