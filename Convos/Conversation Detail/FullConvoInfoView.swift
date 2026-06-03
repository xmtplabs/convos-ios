import ConvosCore
import ConvosMetrics
import SwiftUI

struct FullConvoInfoView: View {
    let onDismiss: () -> Void

    @State private var navState: FullConvoInfoNavigatorImpl = .init()
    @State private var navigator: FullConvoInfoCollector?

    private func ensureNavigator() {
        guard navigator == nil else { return }
        navigator = FullConvoInfoCollector(
            instance: navState,
            delegate: PostHogConfiguration.sharedMetricsDelegate ?? CollectorDelegate()
        )
    }

    var body: some View {
        FeatureInfoSheet(
            title: "Full",
            paragraphs: [
                .init("This convo has reached its max capacity of \(Conversation.maxMembers) people, so you're unable to invite new people in.", style: .primary),
                .init("Invitations will be enabled automatically if space becomes available."),
            ],
            primaryButtonAction: { onDismiss() }
        )
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("full-convo-info-view")
        .onAppear {
            ensureNavigator()
            navState.markScreenAppeared()
        }
        .onDisappear {
            navigator?.closed(context: navState.closeContext())
        }
    }
}

#Preview {
    FullConvoInfoView(onDismiss: {})
        .background(.colorBackgroundSurfaceless)
}
