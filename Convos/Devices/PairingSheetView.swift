import ConvosCore
import SwiftUI

struct PairingSheetView: View {
    @Bindable var viewModel: PairingSheetViewModel
    @Environment(\.dismiss) private var dismiss: DismissAction
    @FocusState private var pinFieldFocused: Bool
    @State private var isHoldingReveal: Bool = false

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
            await viewModel.startPairing()
        }
    }

    @ViewBuilder
    private var centerContent: some View {
        switch viewModel.flowState {
        case let .qrCode(url):
            qrCodeContent(url: url)
                .transition(.blurReplace)

        case let .pinEntry(deviceName):
            pinEntryContent(deviceName: deviceName)
                .transition(.blurReplace)

        case .syncing:
            syncingContent
                .transition(.blurReplace)

        case let .completed(deviceName):
            completedContent(deviceName: deviceName)
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
    private func qrCodeContent(url: String) -> some View {
        VStack(spacing: DesignConstants.Spacing.step4x) {
            if let qrURL = URL(string: url), !url.isEmpty {
                QRCodeView(
                    url: qrURL,
                    backgroundColor: .white,
                    foregroundColor: .black,
                    centerImage: Image("convosOrangeIcon")
                )
                .blur(radius: isHoldingReveal ? 0 : 20)
                .opacity(isHoldingReveal ? 1.0 : 0.75)
                .scaleEffect(isHoldingReveal ? 1.0 : 0.9)
                .animation(.easeInOut(duration: 0.2), value: isHoldingReveal)
                .padding(DesignConstants.Spacing.step6x)
                .background(.white)
                .clipShape(RoundedRectangle(cornerRadius: DesignConstants.CornerRadius.large))
                .accessibilityIdentifier("pairing-qr-code")
            } else {
                ProgressView()
                    .frame(width: 220, height: 220)
            }

            Text("Scan this code with your new device to pair")
                .font(.subheadline)
                .foregroundStyle(.colorTextSecondary)
                .multilineTextAlignment(.center)

            if let qrURL = URL(string: url), !url.isEmpty {
                ShareLink(item: qrURL) {
                    HStack(spacing: DesignConstants.Spacing.stepX) {
                        Image(systemName: "square.and.arrow.up")
                            .font(.caption2)
                        Text("Share")
                            .font(.caption)
                    }
                    .foregroundStyle(.colorTextPrimary)
                    .padding(.vertical, DesignConstants.Spacing.stepX)
                    .padding(.horizontal, DesignConstants.Spacing.step3x)
                    .background(
                        Capsule()
                            .stroke(.colorBorderSubtle, lineWidth: 1)
                    )
                }
                .accessibilityIdentifier("share-pairing-link")
            }

            ExpiryLabel(secondsRemaining: viewModel.secondsRemaining)
        }
    }

    @ViewBuilder
    private func pinEntryContent(deviceName: String) -> some View {
        VStack(spacing: DesignConstants.Spacing.step4x) {
            Text(deviceName)
                .font(.subheadline)
                .foregroundStyle(.colorTextSecondary)

            Text("Enter the code shown on the new device")
                .font(.subheadline)
                .foregroundStyle(.colorTextSecondary)

            PinEntryField(pin: $viewModel.enteredPin, isFocused: $pinFieldFocused)
                .accessibilityIdentifier("pin-entry-field")
                .onAppear {
                    pinFieldFocused = true
                }

            ExpiryLabel(secondsRemaining: viewModel.secondsRemaining)
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

    @ViewBuilder
    private func completedContent(deviceName: String) -> some View {
        VStack(spacing: DesignConstants.Spacing.step4x) {
            Image(systemName: "iphone.badge.checkmark")
                .font(.system(size: 56))
                .foregroundStyle(.colorFillPrimary)
                .symbolRenderingMode(.hierarchical)

            Text(deviceName)
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
        case .qrCode:
            HoldToRevealButton(isHolding: $isHoldingReveal)
                .accessibilityIdentifier("hold-to-reveal-button")

        case .pinEntry:
            let approveAction = { viewModel.triggerApprove() }
            Button(action: approveAction) {
                Text("Approve")
            }
            .convosButtonStyle(.rounded(fullWidth: true))
            .disabled(!viewModel.isApproveEnabled)
            .accessibilityIdentifier("approve-button")

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
        case .completed:
            EmptyView()

        case .syncing:
            EmptyView()

        default:
            let cancelAction = {
                viewModel.triggerCancel()
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

// MARK: - Hold To Reveal Button

private struct HoldToRevealButton: View {
    @Binding var isHolding: Bool
    @State private var buttonSize: CGSize = .zero
    @State private var isDragging: Bool = false

    var body: some View {
        Text("Hold to reveal")
            .font(.subheadline)
            .lineLimit(1)
            .frame(maxWidth: .infinity)
            .padding(.vertical, DesignConstants.Spacing.step4x)
            .padding(.horizontal, DesignConstants.Spacing.step4x)
            .background(
                GeometryReader { geo in
                    Color.clear
                        .onAppear { buttonSize = geo.size }
                        .onChange(of: geo.size) { _, newSize in buttonSize = newSize }
                }
            )
            .background(.colorFillPrimary)
            .clipShape(Capsule())
            .foregroundColor(.colorTextPrimaryInverted)
            .opacity(isHolding ? 0.8 : 1.0)
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        let inside = value.location.x >= 0
                            && value.location.x <= buttonSize.width
                            && value.location.y >= 0
                            && value.location.y <= buttonSize.height
                        if inside != isHolding {
                            isHolding = inside
                        }
                    }
                    .onEnded { _ in
                        isHolding = false
                    }
            )
            .sensoryFeedback(.impact(weight: .light), trigger: isHolding) { _, newValue in
                newValue
            }
            .accessibilityLabel("Hold to reveal")
    }
}

#Preview("QR Code - Blurred") {
    @Previewable @State var isPresented: Bool = true

    VStack {
        let action = { isPresented = true }
        Button(action: action) { Text("Show") }
    }
    .selfSizingSheet(isPresented: $isPresented) {
        let vm = PairingSheetViewModel(vaultManager: .preview)
        PairingSheetView(viewModel: vm)
            .padding(.top, DesignConstants.Spacing.step5x)
    }
}

#Preview("Pin Entry") {
    PairingSheetPreview(state: .pinEntry(deviceName: "Jarod's iPad"))
}

#Preview("Syncing") {
    PairingSheetPreview(state: .syncing, canDismiss: false)
}

#Preview("Completed") {
    PairingSheetPreview(state: .completed(deviceName: "Jarod's iPad"), title: "Device added")
}

private struct PairingSheetPreview: View {
    let state: PairingFlowState
    var canDismiss: Bool = true
    var title: String = "Pair new device"

    var body: some View {
        let vm = PairingSheetViewModel(vaultManager: .preview)
        PairingSheetView(viewModel: vm)
            .onAppear {
                vm.flowState = state
                vm.canDismiss = canDismiss
                vm.title = title
            }
    }
}
