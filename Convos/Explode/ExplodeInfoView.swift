import ConvosMetrics
import SwiftUI

struct ExplodeInfoView: View {
    @Environment(\.dismiss) var dismiss: DismissAction
    @State private var navState: ExplodeInfoNavigatorImpl = .init()
    @State private var navigator: ExplodeInfoCollector?

    private func ensureNavigator() {
        guard navigator == nil else { return }
        navigator = ExplodeInfoCollector(
            instance: navState,
            delegate: PostHogConfiguration.sharedMetricsDelegate ?? CollectorDelegate()
        )
    }

    var body: some View {
        FeatureInfoSheet(
            tagline: "Real life is off the record.™",
            title: "Exploding convos",
            paragraphs: [
                .init("Messages and Members are destroyed forever, and there's no record that the convo ever happened."),
            ],
            primaryButtonAction: { dismiss() }
        )
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("explode-info-view")
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
    @Previewable @State var presentingExplodeInfo: Bool = false
    VStack {
        Button {
            presentingExplodeInfo.toggle()
        } label: {
            Text("Toggle")
        }
    }
    .selfSizingSheet(isPresented: $presentingExplodeInfo) {
        ExplodeInfoView()
    }
}
