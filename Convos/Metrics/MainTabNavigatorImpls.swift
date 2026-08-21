import ConvosMetrics
import Foundation
import Observation

/// Shared marker for the screen-lifecycle helpers every NavigatorImpl in
/// the metrics layer exposes. Lets `MainTabView` keep its tab-aware
/// lifecycle dispatch (`navStateForTab(_:)` -> `closeContext()` /
/// `markScreenAppeared()`) generic over which tab's NavigatorImpl it
/// happens to be holding.
@MainActor
protocol NavigatorLifecycle: AnyObject {
    func markScreenAppeared()
    func closeContext() -> ScreenContext
}

@MainActor
@Observable
final class TabRootNavigatorImpl: @preconcurrency TabRootNavigator, NavigatorLifecycle {
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

    func navigateTo(conversations: ConversationsNavigatorArgs) {}
    func navigateTo(stuffOverview: StuffOverviewNavigatorArgs) {}
    func navigateTo(contacts: ContactsNavigatorArgs) {}
    func closed(context: ScreenContext) {}
}

@MainActor
@Observable
final class ContactsNavigatorImpl: @preconcurrency ContactsNavigator, NavigatorLifecycle {
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

    func navigateTo(contactCard: ContactCardNavigatorArgs) {}
    func present(newConversation: NewConversationNavigatorArgs) {}
    func present(appSettings: AppSettingsNavigatorArgs) {}
    func present(agentBuilder: AgentBuilderNavigatorArgs) {}
    func closed(context: ScreenContext) {}
}

/// Lifecycle-only navigator for the Agents tab. The shared `ConvosMetrics`
/// package has no Agents screen, so this conforms to `NavigatorLifecycle`
/// alone: the shell can still dispatch appear/close for the tab, and no event
/// is emitted until the package has one that means what happened.
@MainActor
@Observable
final class AgentsNavigatorImpl: NavigatorLifecycle {
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
}
