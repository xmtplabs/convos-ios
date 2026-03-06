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

            buttons
                .padding(.top, DesignConstants.Spacing.step4x)
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
        case .connecting:
            EmptyView()

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

// MARK: - Pin Entry Field

private struct PinEntryField: View {
    @Binding var pin: String
    @FocusState.Binding var isFocused: Bool

    var body: some View {
        HStack(spacing: DesignConstants.Spacing.step3x) {
            ForEach(0 ..< 6, id: \.self) { index in
                let digit = digitAt(index)
                ZStack {
                    RoundedRectangle(cornerRadius: DesignConstants.CornerRadius.small)
                        .fill(.colorBackgroundRaisedSecondary)
                        .frame(width: 44, height: 56)
                        .overlay(
                            RoundedRectangle(cornerRadius: DesignConstants.CornerRadius.small)
                                .stroke(
                                    index == pin.count ? Color.colorFillPrimary : .colorBorderSubtle,
                                    lineWidth: index == pin.count ? 2 : 1
                                )
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
    JoinerPairingSheetPreview(state: .waitingForEmoji(emojis: ["🦊", "🎸", "🌊"]), title: "Confirm pairing")
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
