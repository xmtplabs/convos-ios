import ConvosMetrics
import SwiftUI

struct PinLimitInfoView: View {
    @State private var navState: PinLimitInfoNavigatorImpl = .init()
    @State private var navigator: PinLimitInfoCollector?

    private func ensureNavigator() {
        guard navigator == nil else { return }
        navigator = PinLimitInfoCollector(
            instance: navState,
            delegate: PostHogConfiguration.sharedMetricsDelegate ?? CollectorDelegate()
        )
    }

    var body: some View {
        InfoView(
            title: "Pin limit reached",
            description: "You can pin up to 9 convos. To pin this convo, unpin another one first."
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
    PinLimitInfoView()
}
