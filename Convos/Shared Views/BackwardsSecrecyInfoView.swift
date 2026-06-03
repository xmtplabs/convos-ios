import ConvosMetrics
import SwiftUI

struct BackwardsSecrecyInfoView: View {
    @Environment(\.dismiss) var dismiss: DismissAction

    @State private var navState: BackwardsSecrecyInfoNavigatorImpl = .init()
    @State private var navigator: BackwardsSecrecyInfoCollector?

    private func ensureNavigator() {
        guard navigator == nil else { return }
        navigator = BackwardsSecrecyInfoCollector(
            instance: navState,
            delegate: PostHogConfiguration.sharedMetricsDelegate ?? CollectorDelegate()
        )
    }

    var body: some View {
        FeatureInfoSheet(
            tagline: "Private chat for the AI era",
            title: "No looking back",
            paragraphs: [
                .init("For privacy, convo members can\u{2019}t see messages sent before they joined.", style: .primary),
                .init("This ensures that the convo history remains private, no matter who else joins."),
                .init("\u{201C}Backwards Secrecy\u{201D} is cryptographically enforced.", size: .footnote),
            ],
            primaryButtonAction: { dismiss() },
            showDragIndicator: true
        )
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
    @Previewable @State var isPresented: Bool = true
    VStack {
        let action = { isPresented.toggle() }
        Button(action: action) { Text("Show") }
    }
    .selfSizingSheet(isPresented: $isPresented) {
        BackwardsSecrecyInfoView()
    }
}
