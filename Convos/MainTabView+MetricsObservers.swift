import SwiftUI

/// Extracted modifier carrying the metrics `.onChange` observers for the
/// tab shell. Bundled into a single `ViewModifier` because chaining all
/// eight observers inline on `MainTabView.body` pushed the body's
/// type-check time past the 300ms warning-as-error threshold (see
/// CLAUDE.md build-performance notes). Each observer is a one-liner
/// that dispatches to a `handle*` helper defined on `MainTabView`; this
/// modifier is just the trampoline.
extension MainTabView {
    struct MetricsObservers: ViewModifier {
        let activeTab: ConvosTab
        let scenePhase: ScenePhase
        let stuffPushedItemId: String?
        let contactsPushedItemId: String?
        let presentingAppSettings: Bool
        let selectedConversationId: String?
        let agentBuilderPresenting: Bool
        let newConversationPresenting: Bool

        let onActiveTabChanged: (ConvosTab, ConvosTab) -> Void
        let onScenePhaseChanged: (ScenePhase) -> Void
        let onStuffPushChanged: (String?, String?) -> Void
        let onContactsPushChanged: (String?, String?) -> Void
        let onAppSettingsPresented: (Bool) -> Void
        let onSelectedConversationChanged: (String?, String?) -> Void
        let onAgentBuilderPresented: (Bool, Bool) -> Void
        let onNewConversationPresented: (Bool, Bool) -> Void

        func body(content: Content) -> some View {
            content
                .onChange(of: activeTab) { o, n in onActiveTabChanged(o, n) }
                .onChange(of: scenePhase) { _, n in onScenePhaseChanged(n) }
                .onChange(of: stuffPushedItemId) { o, n in onStuffPushChanged(o, n) }
                .onChange(of: contactsPushedItemId) { o, n in onContactsPushChanged(o, n) }
                .onChange(of: presentingAppSettings) { _, n in onAppSettingsPresented(n) }
                .onChange(of: selectedConversationId) { o, n in onSelectedConversationChanged(o, n) }
                .onChange(of: agentBuilderPresenting) { o, n in onAgentBuilderPresented(n, o) }
                .onChange(of: newConversationPresenting) { o, n in onNewConversationPresented(n, o) }
        }
    }
}
