import ConvosCore
import SwiftUI

struct JoinerPairingSheetView: View {
    @Bindable var viewModel: JoinerPairingSheetViewModel
    @Environment(\.dismiss) private var dismiss: DismissAction

    var body: some View {
        VStack(alignment: .leading, spacing: DesignConstants.Spacing.step4x) {
            Text(viewModel.title)
                .font(.convosTitle)
                .tracking(Font.convosTitleTracking)
                .animation(.easeInOut(duration: 0.3), value: viewModel.title)

            centerContent
                .frame(maxWidth: .infinity)
                .frame(minHeight: 260)

            buttons
                .padding(.top, DesignConstants.Spacing.step2x)
        }
        .padding([.leading, .trailing], DesignConstants.Spacing.step10x)
        .padding(.top, DesignConstants.Spacing.step8x)
        .padding(.bottom, DesignConstants.Spacing.step6x)
        .interactiveDismissDisabled(!viewModel.canDismiss)
        .task {
            viewModel.startCountdown()
        }
    }

    @ViewBuilder
    private var centerContent: some View {
        switch viewModel.flowState {
        case let .showingPin(pin, _):
            pinDisplayContent(pin: pin)
                .transition(.blurReplace)

        case .syncing:
            syncingContent
                .transition(.blurReplace)

        case .completed:
            completedContent
                .transition(.blurReplace)

        case let .failed(message):
            failedContent(message: message)
                .transition(.blurReplace)

        case .expired:
            expiredContent
                .transition(.blurReplace)
        }
    }

    @ViewBuilder
    private func pinDisplayContent(pin: String) -> some View {
        VStack(spacing: DesignConstants.Spacing.step6x) {
            VStack(spacing: DesignConstants.Spacing.step3x) {
                Text(viewModel.formattedPin)
                    .font(.system(size: 48, weight: .bold, design: .rounded))
                    .kerning(4)
                    .foregroundStyle(.colorTextPrimary)
                    .accessibilityIdentifier("pairing-pin-display")

                Text("Expires in \(viewModel.secondsRemaining)s")
                    .font(.caption)
                    .foregroundStyle(.colorTextTertiary)
                    .monospacedDigit()
                    .contentTransition(.numericText())
                    .animation(.linear(duration: 0.3), value: viewModel.secondsRemaining)
                    .accessibilityIdentifier("pairing-countdown")
            }

            VStack(spacing: DesignConstants.Spacing.step2x) {
                Text("\(viewModel.initiatorDeviceName) is requesting to pair")
                    .font(.subheadline)
                    .foregroundStyle(.colorTextSecondary)

                Text("Enter the code above on \(viewModel.initiatorDeviceName) to finish pairing")
                    .font(.subheadline)
                    .foregroundStyle(.colorTextSecondary)
                    .multilineTextAlignment(.center)
            }
        }
    }

    private var syncingContent: some View {
        VStack(spacing: DesignConstants.Spacing.step4x) {
            RotatingSyncIcon()
                .frame(width: 64, height: 64)

            Text("Pairing device...")
                .font(.subheadline)
                .foregroundStyle(.colorTextSecondary)
        }
    }

    private var completedContent: some View {
        VStack(spacing: DesignConstants.Spacing.step4x) {
            Image(systemName: "iphone.badge.checkmark")
                .font(.system(size: 56))
                .foregroundStyle(.colorFillPrimary)
                .symbolRenderingMode(.hierarchical)

            Text("Successfully paired")
                .font(.subheadline)
                .foregroundStyle(.colorTextSecondary)
        }
    }

    @ViewBuilder
    private func failedContent(message: String) -> some View {
        VStack(spacing: DesignConstants.Spacing.step4x) {
            Image(systemName: "exclamationmark.triangle")
                .font(.system(size: 56))
                .foregroundStyle(.colorCaution)

            Text(message)
                .font(.subheadline)
                .foregroundStyle(.colorTextSecondary)
                .multilineTextAlignment(.center)
        }
    }

    private var expiredContent: some View {
        VStack(spacing: DesignConstants.Spacing.step4x) {
            Image(systemName: "clock.badge.xmark")
                .font(.system(size: 56))
                .foregroundStyle(.colorTextTertiary)

            Text("Pairing expired. Please try again.")
                .font(.subheadline)
                .foregroundStyle(.colorTextSecondary)
                .multilineTextAlignment(.center)
        }
    }

    @ViewBuilder
    private var buttons: some View {
        VStack(spacing: DesignConstants.Spacing.step2x) {
            primaryButton
            secondaryButton
        }
    }

    @ViewBuilder
    private var primaryButton: some View {
        switch viewModel.flowState {
        case .showingPin:
            EmptyView()

        case .syncing:
            let action = {}
            Button(action: action) {
                Text("Pairing...")
            }
            .convosButtonStyle(.rounded(fullWidth: true))
            .disabled(true)

        case .completed:
            let gotItAction = { dismiss() }
            Button(action: gotItAction) {
                Text("Got it")
            }
            .convosButtonStyle(.rounded(fullWidth: true))
            .accessibilityIdentifier("got-it-button")

        case .failed, .expired:
            let dismissAction = { dismiss() }
            Button(action: dismissAction) {
                Text("Dismiss")
            }
            .convosButtonStyle(.rounded(fullWidth: true))
        }
    }

    @ViewBuilder
    private var secondaryButton: some View {
        switch viewModel.flowState {
        case .completed, .syncing, .failed, .expired:
            EmptyView()

        default:
            let cancelAction = {
                viewModel.cancel()
                dismiss()
            }
            Button(action: cancelAction) {
                Text("Cancel")
            }
            .convosButtonStyle(.text)
            .frame(maxWidth: .infinity)
            .accessibilityIdentifier("cancel-pairing")
        }
    }
}

#Preview("Showing Pin") {
    JoinerPairingSheetPreview(state: .showingPin(pin: "482916", expiresAt: Date().addingTimeInterval(45)))
}

#Preview("Syncing") {
    JoinerPairingSheetPreview(state: .syncing)
}

#Preview("Completed") {
    JoinerPairingSheetPreview(state: .completed, title: "Device paired")
}

#Preview("Expired") {
    JoinerPairingSheetPreview(state: .expired)
}

private struct JoinerPairingSheetPreview: View {
    let state: JoinerPairingFlowState
    var title: String = "Request to pair"

    var body: some View {
        let vm = JoinerPairingSheetViewModel(pairingId: "test-123")
        JoinerPairingSheetView(viewModel: vm)
            .onAppear {
                vm.flowState = state
                vm.title = title
            }
    }
}
