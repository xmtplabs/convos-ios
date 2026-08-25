import ConvosBridge
import Foundation

/// Native destinations for the home page's `window.convos` invite/chat calls.
/// Mirrors Android's `DesktopBridgeNavigation`: defaults are no-ops so
/// bridge-backed surfaces that aren't conversation-scoped (the browser
/// popups) can leave them unset. Each closure should read live conversation
/// state when invoked, since the owning bridge is created once per web view
/// and refreshed on every update pass.
struct HomeBridgeNavigation {
    var showShareSheet: @MainActor @Sendable () -> Void = {}
    var showScan: @MainActor @Sendable () -> Void = {}
    var showInviteCode: @MainActor @Sendable () -> Void = {
        Log.warning("HomeBridgeNavigation.showInviteCode invoked on the default (unwired) navigation - the web view showing this page was not given a conversation-scoped bridgeNavigation")
    }
    var showInvitePicker: @MainActor @Sendable () -> Void = {}
    var showMembersList: @MainActor @Sendable () -> Void = {}
    var showAgentDm: @MainActor @Sendable () -> Void = {}
}

/// Main-actor state shared between the hosting web view (which refreshes the
/// navigation closures as SwiftUI re-renders) and the plugin implementations
/// (which hop here from the bridge dispatcher's arbitrary tasks).
///
/// Agent status is a local placeholder matching the Android stubs: real
/// wiring to the conversation view model is a follow-up.
@MainActor
final class HomeBridgeHost {
    var navigation: HomeBridgeNavigation = HomeBridgeNavigation()
    var onMarkReady: () -> Void = {}

    private(set) var agentStatus: AgentStatus = AgentStatus(state: .NONE, progress: nil)
    private var agentStatusContinuations: [UUID: AsyncStream<AgentStatus>.Continuation] = [:]

    func updateAgentStatus(_ status: AgentStatus) {
        agentStatus = status
        for continuation in agentStatusContinuations.values {
            continuation.yield(status)
        }
    }

    /// Registers a stream observer, immediately yielding the current status so
    /// subscribers start with a value (matching Android's state flow).
    func addAgentStatusObserver(id: UUID, continuation: AsyncStream<AgentStatus>.Continuation) {
        agentStatusContinuations[id] = continuation
        continuation.yield(agentStatus)
    }

    func removeAgentStatusObserver(id: UUID) {
        agentStatusContinuations.removeValue(forKey: id)
    }
}

/// Builds the plugin dispatcher list wired into a home surface's
/// `ConvosWebBridge`, one implementation per shared `@BridgePlugin` interface
/// (mirroring Android's `desktopBridgeHandlers`).
enum HomeBridgePlugins {
    @MainActor
    static func dispatchers(host: HomeBridgeHost) -> [BridgePluginDispatcher] {
        [
            EventsPluginDispatcher(HomeEventsPlugin()),
            AppPluginDispatcher(HomeAppPlugin(host: host)),
            InvitePluginDispatcher(HomeInvitePlugin(host: host)),
            ChatPluginDispatcher(HomeChatPlugin(host: host)),
            ThingsPluginDispatcher(HomeThingsPlugin()),
            DesktopPluginDispatcher(HomeDesktopPlugin()),
        ]
    }
}

// The bridge dispatcher invokes plugin methods off the main actor, so each
// implementation is a non-isolated Sendable class that hops to the main actor
// before touching the host.

private final class HomeEventsPlugin: EventsPlugin, Sendable {
    func trackEvent(name: String) {
        Log.info("bridge trackEvent: \(name)")
    }
}

private final class HomeAppPlugin: AppPlugin, Sendable {
    private let host: HomeBridgeHost

    init(host: HomeBridgeHost) {
        self.host = host
    }

    func markReady() {
        let host = host
        Log.info("bridge app.markReady received")
        Task { @MainActor in host.onMarkReady() }
    }
}

private final class HomeInvitePlugin: InvitePlugin, Sendable {
    private let host: HomeBridgeHost

    init(host: HomeBridgeHost) {
        self.host = host
    }

    func showShareSheet() {
        let host = host
        Task { @MainActor in host.navigation.showShareSheet() }
    }

    func showScan() {
        let host = host
        Task { @MainActor in host.navigation.showScan() }
    }

    func showInviteCode() {
        let host = host
        Log.info("bridge invite.showInviteCode received; hopping to main actor to invoke navigation")
        Task { @MainActor in host.navigation.showInviteCode() }
    }

    func showInvitePicker() {
        let host = host
        Task { @MainActor in host.navigation.showInvitePicker() }
    }
}

private final class HomeChatPlugin: ChatPlugin, Sendable {
    private let host: HomeBridgeHost

    init(host: HomeBridgeHost) {
        self.host = host
    }

    func showMembersList() {
        let host = host
        Task { @MainActor in host.navigation.showMembersList() }
    }

    func showAgentDm() {
        let host = host
        Task { @MainActor in host.navigation.showAgentDm() }
    }

    func getAgentStatus() async throws -> AgentStatus {
        await MainActor.run { [host] in host.agentStatus }
    }

    func requestAgentJoin() {
        let host = host
        Task { @MainActor in
            host.updateAgentStatus(AgentStatus(state: .JOINING, progress: 0))
        }
    }

    func onAgentStatusChanged() -> AsyncStream<AgentStatus> {
        let host = host
        return AsyncStream { continuation in
            let id = UUID()
            Task { @MainActor in
                host.addAgentStatusObserver(id: id, continuation: continuation)
            }
            continuation.onTermination = { _ in
                Task { @MainActor in host.removeAgentStatusObserver(id: id) }
            }
        }
    }
}

private final class HomeThingsPlugin: ThingsPlugin, Sendable {
    // Future wiring point: the "Things" surface in ConversationInfoView
    // (AgentFilesLinksView); stubbed for parity with Android.
    func showThingsList() {
        Log.debug("bridge showThingsList (stub)")
    }

    func getThingsList() async throws -> [ThingInfo] {
        []
    }
}

private final class HomeDesktopPlugin: DesktopPlugin, Sendable {
    func replyToWidget(id: String, widget: WidgetRef) {
        Log.debug("bridge replyToWidget(\(id), \(widget.title))")
    }

    func popupWidget(id: String, url: String, bounds: PopupBounds) {
        Log.debug("bridge popupWidget(\(id), \(url))")
    }
}
