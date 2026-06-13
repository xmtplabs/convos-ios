import ConvosMetrics
import SwiftUI

struct SetupProfileSuccessView: View {
    var body: some View {
        Group {
            HStack(spacing: DesignConstants.Spacing.stepX) {
                Image(systemName: "lanyardcard.fill")
                    .foregroundStyle(.colorLava)

                Text("Profile saved")
                    .font(.callout)
                    .foregroundStyle(.colorTextPrimary)
            }
            .padding(.vertical, DesignConstants.Spacing.step3HalfX)
            .padding(.horizontal, DesignConstants.Spacing.step4x)
        }
        .background(
            Capsule()
                .fill(.colorFillMinimal)
        )
    }
}

#Preview {
    SetupProfileSuccessView()
}

struct SetupProfileView: View {
    let action: () -> Void

    @State private var navState: SetupProfileNavigatorImpl = .init()
    @State private var navigator: SetupProfileCollector?

    private func ensureNavigator() {
        guard navigator == nil else { return }
        navigator = SetupProfileCollector(
            instance: navState,
            delegate: PostHogConfiguration.sharedMetricsDelegate ?? CollectorDelegate()
        )
    }

    var body: some View {
        Button {
            action()
        } label: {
            HStack(spacing: DesignConstants.Spacing.stepX) {
                Image(systemName: "lanyardcard.fill")
                    .foregroundStyle(.colorLava)
                    .accessibilityHidden(true)
                Text("Add your name and pic")
                    .font(.callout)
                    .foregroundStyle(.colorTextPrimaryInverted)
            }
            .padding(.vertical, DesignConstants.Spacing.step3HalfX)
            .padding(.horizontal, DesignConstants.Spacing.step4x)
            .background(
                Capsule()
                    .fill(.colorBackgroundInverted)
            )
        }
        .accessibilityLabel("Add your name and pic")
        .accessibilityIdentifier("setup-profile-button")
        .transition(.blurReplace)
        .hoverEffect(.lift)
        .padding(.vertical, DesignConstants.Spacing.step4x)
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
    VStack(spacing: 20) {
        SetupProfileView {}
    }
    .padding()
}
