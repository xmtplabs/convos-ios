import ConvosMetrics
import SwiftUI

struct RevealMediaInfoSheet: View {
    @Environment(\.dismiss) var dismiss: DismissAction

    @State private var navState: RevealMediaInfoNavigatorImpl = .init()
    @State private var navigator: RevealMediaInfoCollector?

    private func ensureNavigator() {
        guard navigator == nil else { return }
        navigator = RevealMediaInfoCollector(
            instance: navState,
            delegate: PostHogConfiguration.sharedMetricsDelegate ?? CollectorDelegate()
        )
    }

    var body: some View {
        FeatureInfoSheet(
            tagline: "Real life is off the record.™",
            title: "Reveal",
            subtitle: "View things when you choose to. Blur or reveal any pic, anytime.",
            paragraphs: [
                .init("Revealing is a personal preference, and no one else in the convo will know your choice."),
            ],
            primaryButtonAction: { dismiss() },
            learnMoreURL: URL(string: "https://learn.convos.org/reveal")
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
        Button { isPresented.toggle() } label: { Text("Show") }
    }
    .selfSizingSheet(isPresented: $isPresented) {
        RevealMediaInfoSheet()
    }
}
