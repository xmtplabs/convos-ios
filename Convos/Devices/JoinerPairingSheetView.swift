import ConvosCore
import SwiftUI

struct JoinerPairingSheetView: View {
    @Bindable var viewModel: JoinerPairingSheetViewModel
    @Environment(\.dismiss) private var dismiss: DismissAction
    @FocusState private var pinFieldFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: DesignConstants.Spacing.step4x) {
            Text(viewModel.title)
                .font(.convosTitle)
                .tracking(Font.convosTitleTracking)
                .animation(.easeInOut(duration: 0.3), value: viewModel.title)

            centerContent
                .frame(maxWidth: .infinity)
                .animation(.easeInOut(duration: 0.35), value: viewModel.flowState)

            buttons
                .padding(.top, DesignConstants.Spacing.step4x)
                .animation(.easeInOut(duration: 0.35), value: viewModel.flowState)
        }
        .padding([.leading, .trailing], DesignConstants.Spacing.step10x)
        .padding(.top, DesignConstants.Spacing.step8x)
        .padding(.bottom, DesignConstants.Spacing.step6x)
        .interactiveDismissDisabled(!viewModel.canDismiss)
        .task {
            viewModel.startCountdown()
            await viewModel.sendJoinRequest()
        }
    }

    @ViewBuilder
    private var centerContent: some View {
        switch viewModel.flowState {
        case .connecting:
            connectingContent
                .transition(.blurReplace)

        case .needsDataDeletion:
            needsDataDeletionContent
                .transition(.blurReplace)

        case .deletingData:
            deletingDataContent
                .transition(.blurReplace)

        case .pinEntry:
            pinEntryContent
                .transition(.blurReplace)

        case let .waitingForEmoji(emojis):
            emojiDisplayContent(emojis: emojis)
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

    private var needsDataDeletionContent: some View {
        VStack(spacing: DesignConstants.Spacing.step4x) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 48))
                .foregroundStyle(.colorCaution)
                .symbolRenderingMode(.hierarchical)

            Text("This device already has a Convos account.")
                .font(.headline)
                .foregroundStyle(.colorTextPrimary)
                .multilineTextAlignment(.center)

            Text("Pairing with \"\(viewModel.initiatorDeviceName)\" will replace this device's account. Existing conversations and data on this device will be deleted.")
                .font(.subheadline)
                .foregroundStyle(.colorTextSecondary)
                .multilineTextAlignment(.center)
        }
    }

    private var deletingDataContent: some View {
        VStack(spacing: DesignConstants.Spacing.step4x) {
            RotatingSyncIcon()
                .frame(width: 64, height: 64)
            Text("Deleting existing data...")
                .font(.subheadline)
                .foregroundStyle(.colorTextSecondary)
        }
    }

    private var connectingContent: some View {
        VStack(spacing: DesignConstants.Spacing.step4x) {
            Text("\"\(viewModel.initiatorDeviceName)\" is requesting to pair. Paired devices sync all conversations.")
                .font(.subheadline)
                .foregroundStyle(.colorTextPrimary)
                .frame(maxWidth: .infinity, alignment: .leading)

            ProgressView()
                .frame(height: 44)

            ExpiryLabel(secondsRemaining: viewModel.secondsRemaining)
        }
    }

    @ViewBuilder
    private var pinEntryContent: some View {
        VStack(spacing: DesignConstants.Spacing.step4x) {
            Text("Enter the code shown on \"\(viewModel.initiatorDeviceName)\" to finish pairing.")
                .font(.subheadline)
                .foregroundStyle(.colorTextPrimary)
                .frame(maxWidth: .infinity, alignment: .leading)

            PinEntryField(pin: $viewModel.enteredPin, isFocused: $pinFieldFocused)
                .accessibilityIdentifier("pin-entry-field")
                .onAppear {
                    pinFieldFocused = true
                }

            ExpiryLabel(secondsRemaining: viewModel.secondsRemaining)
        }
    }

    @ViewBuilder
    private func emojiDisplayContent(emojis: [String]) -> some View {
        VStack(spacing: DesignConstants.Spacing.step4x) {
            Text("Make sure these emoji match on \"\(viewModel.initiatorDeviceName)\".")
                .font(.subheadline)
                .foregroundStyle(.colorTextPrimary)
                .frame(maxWidth: .infinity, alignment: .leading)

            HStack(spacing: DesignConstants.Spacing.step6x) {
                ForEach(emojis, id: \.self) { emoji in
                    Text(emoji)
                        .font(.system(size: 56))
                }
            }
            .accessibilityIdentifier("pairing-emoji-fingerprint")

            Text("Waiting for confirmation...")
                .font(.subheadline)
                .foregroundStyle(.colorTextSecondary)
        }
    }

    private var syncingContent: some View {
        VStack(spacing: DesignConstants.Spacing.step4x) {
            RotatingSyncIcon()
                .frame(width: 64, height: 64)

            Text("Adopting your identity...")
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
        case .connecting:
            EmptyView()

        case .needsDataDeletion, .deletingData:
            let isDeleting = viewModel.flowState == .deletingData
            let confirmAction = { viewModel.triggerConfirmDeleteAndPair() }
            HoldToErasePairButton(isDeleting: isDeleting, onConfirm: confirmAction)
                .hoverEffect(.lift)

        case .pinEntry:
            let submitAction: @MainActor () -> Void = { Task { await viewModel.submitPin() } }
            Button(action: submitAction) {
                Text("Submit")
            }
            .convosButtonStyle(.rounded(fullWidth: true))
            .disabled(!viewModel.isPinComplete)
            .accessibilityIdentifier("submit-pin-button")

        case .waitingForEmoji:
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
        case .completed, .syncing, .failed, .expired, .deletingData:
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

private struct HoldToErasePairButton: View {
    let isDeleting: Bool
    let onConfirm: () -> Void

    private var buttonConfig: HoldToConfirmStyleConfig {
        var config = HoldToConfirmStyleConfig.default
        config.duration = 3.0
        config.backgroundColor = .colorCaution
        return config
    }

    var body: some View {
        Button {
            onConfirm()
        } label: {
            ZStack {
                Text("Hold to erase and pair")
                    .opacity(isDeleting ? 0 : 1)
                Text("Erasing...")
                    .opacity(isDeleting ? 1 : 0)
            }
            .animation(.easeInOut(duration: 0.2), value: isDeleting)
            .foregroundStyle(.white)
            .frame(maxWidth: .infinity)
        }
        .disabled(isDeleting)
        .buttonStyle(HoldToConfirmPrimitiveStyle(config: buttonConfig))
        .accessibilityLabel(isDeleting ? "Erasing data" : "Hold to erase data and pair")
        .accessibilityHint(isDeleting ? "" : "Hold to confirm")
        .accessibilityIdentifier("hold-to-erase-and-pair-button")
    }
}

private struct PinEntryField: View {
    @Binding var pin: String
    @FocusState.Binding var isFocused: Bool

    var body: some View {
        HStack(spacing: DesignConstants.Spacing.step3x) {
            ForEach(0 ..< 6, id: \.self) { index in
                let digit = digitAt(index)
                ZStack {
                    let isCurrent = index == pin.count
                    let strokeColor: Color = isCurrent ? Color.colorFillPrimary : Color.colorBorderSubtle
                    let strokeWidth: CGFloat = isCurrent ? 2 : 1
                    RoundedRectangle(cornerRadius: DesignConstants.CornerRadius.small)
                        .fill(.colorBackgroundRaisedSecondary)
                        .frame(width: 44, height: 56)
                        .overlay(
                            RoundedRectangle(cornerRadius: DesignConstants.CornerRadius.small)
                                .stroke(strokeColor, lineWidth: strokeWidth)
                        )

                    Text(digit)
                        .font(.title)
                        .fontWeight(.semibold)
                        .foregroundStyle(.colorTextPrimary)
                }
            }
        }
        .background(
            TextField("", text: $pin)
                .keyboardType(.numberPad)
                .focused($isFocused)
                .opacity(0.01)
                .frame(width: 1, height: 1)
                .onChange(of: pin) { _, newValue in
                    let filtered = String(newValue.filter(\.isNumber).prefix(6))
                    if filtered != newValue {
                        pin = filtered
                    }
                }
        )
        .onTapGesture {
            isFocused = true
        }
    }

    private func digitAt(_ index: Int) -> String {
        guard index < pin.count else { return "" }
        return String(pin[pin.index(pin.startIndex, offsetBy: index)])
    }
}

#Preview("Connecting") {
    JoinerPairingSheetPreview(state: .connecting)
}

#Preview("Pin Entry") {
    JoinerPairingSheetPreview(state: .pinEntry(initiatorInboxId: "test"))
}

#Preview("Emoji Waiting") {
    JoinerPairingSheetPreview(
        state: .waitingForEmoji(emojis: ["🦊", "🎸", "🌊"]),
        title: "Confirm pairing"
    )
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
        let vm = JoinerPairingSheetViewModel(
            pairingId: "test-123",
            pairingService: MockPairingService()
        )
        JoinerPairingSheetView(viewModel: vm)
            .onAppear {
                vm.flowState = state
                vm.title = title
            }
    }
}
