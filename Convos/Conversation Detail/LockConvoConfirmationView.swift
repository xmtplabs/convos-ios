import ConvosMetrics
import SwiftUI

struct LockConvoConfirmationView: View {
    let onLock: () -> Void
    let onCancel: () -> Void

    @State private var navState: LockConvoConfirmationNavigatorImpl = .init()
    @State private var navigator: LockConvoConfirmationCollector?

    private func ensureNavigator() {
        guard navigator == nil else { return }
        navigator = LockConvoConfirmationCollector(
            instance: navState,
            delegate: PostHogConfiguration.sharedMetricsDelegate ?? CollectorDelegate()
        )
    }

    var body: some View {
        VStack(alignment: .leading, spacing: DesignConstants.Spacing.step4x) {
            Text("Lock?")
                .font(.system(.largeTitle))
                .fontWeight(.bold)

            Text("Nobody new can join this convo.")
                .font(.body)
                .foregroundStyle(.colorTextPrimary)

            Text("New convo codes can't be created, and any outstanding codes will no longer work.")
                .font(.body)
                .foregroundStyle(.colorTextSecondary)

            VStack(spacing: DesignConstants.Spacing.step2x) {
                Button {
                    onLock()
                } label: {
                    Text("Lock convo")
                }
                .convosButtonStyle(.rounded(fullWidth: true, backgroundColor: .colorBackgroundInverted))
                .accessibilityIdentifier("lock-convo-confirm-button")

                Button {
                    onCancel()
                } label: {
                    Text("Cancel")
                }
                .convosButtonStyle(.text)
                .frame(maxWidth: .infinity)
                .accessibilityIdentifier("lock-convo-cancel-button")
            }
            .padding(.top, DesignConstants.Spacing.step4x)
        }
        .padding([.leading, .top, .trailing], DesignConstants.Spacing.step10x)
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
    @Previewable @State var presenting: Bool = true
    VStack {
        Button {
            presenting.toggle()
        } label: {
            Text("Toggle")
        }
    }
    .selfSizingSheet(isPresented: $presenting) {
        LockConvoConfirmationView(
            onLock: {},
            onCancel: {}
        )
    }
}
