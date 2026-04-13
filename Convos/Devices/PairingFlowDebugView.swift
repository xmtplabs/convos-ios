import ConvosCore
import SwiftUI

struct PairingFlowDebugView: View {
    var body: some View {
        List {
            Section("Initiator (Device A)") {
                NavigationLink {
                    InitiatorStepperView()
                } label: {
                    Text("Step Through Initiator Flow")
                        .foregroundStyle(.colorTextPrimary)
                }
            }

            Section("Joiner (Device B)") {
                NavigationLink {
                    JoinerStepperView()
                } label: {
                    Text("Step Through Joiner Flow")
                        .foregroundStyle(.colorTextPrimary)
                }
            }
        }
        .navigationTitle("Pairing Flow Debug")
    }
}

private struct InitiatorStep {
    let label: String
    let title: String
    let state: PairingFlowState
    let seconds: Int
}

private struct InitiatorStepperView: View {
    @State private var stepIndex: Int = 0
    @State private var flowState: PairingFlowState = .qrCode(url: "https://dev.convos.org/pair/example?expires=9999999999&name=My-iPhone")
    @State private var title: String = "Pair new device"
    @State private var secondsRemaining: Int = 112
    @State private var isHoldingReveal: Bool = false

    private let steps: [InitiatorStep] = [
        .init(label: "QR Code", title: "Pair new device", state: .qrCode(url: "https://dev.convos.org/pair/example?expires=9999999999&name=My-iPhone"), seconds: 112),
        .init(label: "Showing Pin", title: "Pair new device", state: .showingPin(pin: "482916", deviceName: "Jarod's iPad"), seconds: 87),
        .init(label: "Emoji Confirmation", title: "Confirm pairing", state: .emojiConfirmation(emojis: ["🦊", "🎸", "🌊"], deviceName: "Jarod's iPad"), seconds: 60),
        .init(label: "Syncing", title: "Pair new device", state: .syncing, seconds: 0),
        .init(label: "Completed", title: "Device added", state: .completed(deviceName: "Jarod's iPad"), seconds: 0),
        .init(label: "Failed", title: "Pair new device", state: .failed("Vault is not connected"), seconds: 0),
        .init(label: "Expired", title: "Pair new device", state: .expired, seconds: 0),
    ]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: DesignConstants.Spacing.step4x) {
                Text(title)
                    .font(.convosTitle)
                    .tracking(Font.convosTitleTracking)
                    .animation(.easeInOut(duration: 0.3), value: title)

                initiatorContent
                    .frame(maxWidth: .infinity)
                    .animation(.easeInOut(duration: 0.35), value: flowState)

                initiatorButtons
                    .padding(.top, DesignConstants.Spacing.step4x)
                    .animation(.easeInOut(duration: 0.35), value: flowState)
            }
            .padding(.horizontal, DesignConstants.Spacing.step10x)
            .padding(.top, DesignConstants.Spacing.step8x)
            .padding(.bottom, DesignConstants.Spacing.step6x)
        }
        .safeAreaInset(edge: .bottom) {
            stepperBar
        }
        .navigationTitle("Initiator Flow")
        .navigationBarTitleDisplayMode(.inline)
    }

    @ViewBuilder
    private var initiatorContent: some View {
        switch flowState {
        case let .qrCode(url):
            VStack(spacing: DesignConstants.Spacing.step4x) {
                Text("Scan this code with your new device to pair")
                    .font(.subheadline)
                    .foregroundStyle(.colorTextPrimary)
                    .frame(maxWidth: .infinity, alignment: .leading)

                Text("All devices that are paired sync their existing convos.")
                    .font(.subheadline)
                    .foregroundStyle(.colorTextSecondary)
                    .frame(maxWidth: .infinity, alignment: .leading)

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
                }

                ExpiryLabel(secondsRemaining: secondsRemaining)
            }
            .transition(.blurReplace)

        case let .showingPin(pin, deviceName):
            VStack(spacing: DesignConstants.Spacing.step4x) {
                Text("Share this code with \"\(deviceName)\" to continue pairing.")
                    .font(.subheadline)
                    .foregroundStyle(.colorTextPrimary)
                    .frame(maxWidth: .infinity, alignment: .leading)

                Text(PairingCoordinator.formatPin(pin))
                    .font(.system(size: 64, weight: .bold, design: .rounded))
                    .kerning(4)
                    .foregroundStyle(.colorTextPrimary)
                    .minimumScaleFactor(0.7)
                    .lineLimit(1)

                ExpiryLabel(secondsRemaining: secondsRemaining)
            }
            .transition(.blurReplace)

        case let .emojiConfirmation(emojis, deviceName):
            VStack(spacing: DesignConstants.Spacing.step4x) {
                Text("Make sure these emoji match on \"\(deviceName)\" before confirming.")
                    .font(.subheadline)
                    .foregroundStyle(.colorTextPrimary)
                    .frame(maxWidth: .infinity, alignment: .leading)

                HStack(spacing: DesignConstants.Spacing.step6x) {
                    ForEach(emojis, id: \.self) { emoji in
                        Text(emoji)
                            .font(.system(size: 56))
                    }
                }
            }
            .transition(.blurReplace)

        case .syncing:
            VStack(spacing: DesignConstants.Spacing.step4x) {
                RotatingSyncIcon()
                    .frame(width: 64, height: 64)

                Text("Pairing device...")
                    .font(.subheadline)
                    .foregroundStyle(.colorTextSecondary)
            }
            .transition(.blurReplace)

        case let .completed(deviceName):
            VStack(spacing: DesignConstants.Spacing.step4x) {
                Image(systemName: "iphone.badge.checkmark")
                    .font(.system(size: 56))
                    .foregroundStyle(.colorFillPrimary)
                    .symbolRenderingMode(.hierarchical)

                Text(deviceName)
                    .font(.subheadline)
                    .foregroundStyle(.colorTextSecondary)
            }
            .transition(.blurReplace)

        case let .failed(message):
            VStack(spacing: DesignConstants.Spacing.step4x) {
                Image(systemName: "exclamationmark.triangle")
                    .font(.system(size: 56))
                    .foregroundStyle(.colorCaution)

                Text(message)
                    .font(.subheadline)
                    .foregroundStyle(.colorTextSecondary)
                    .multilineTextAlignment(.center)
            }
            .transition(.blurReplace)

        case .expired:
            VStack(spacing: DesignConstants.Spacing.step4x) {
                Image(systemName: "clock.badge.xmark")
                    .font(.system(size: 56))
                    .foregroundStyle(.colorTextTertiary)

                Text("Pairing expired. Please try again.")
                    .font(.subheadline)
                    .foregroundStyle(.colorTextSecondary)
                    .multilineTextAlignment(.center)
            }
            .transition(.blurReplace)
        }
    }

    @ViewBuilder
    private var initiatorButtons: some View {
        VStack(spacing: DesignConstants.Spacing.step2x) {
            switch flowState {
            case .qrCode:
                HoldToRevealButton(isHolding: $isHoldingReveal)

            case .showingPin:
                EmptyView()

            case .emojiConfirmation:
                let action = {}
                Button(action: action) { Text("Confirm") }
                    .convosButtonStyle(.rounded(fullWidth: true))

            case .syncing:
                let action = {}
                Button(action: action) { Text("Pairing...") }
                    .convosButtonStyle(.rounded(fullWidth: true))
                    .disabled(true)

            case .completed:
                let action = {}
                Button(action: action) { Text("Got it") }
                    .convosButtonStyle(.rounded(fullWidth: true))

            case .failed, .expired:
                let action = {}
                Button(action: action) { Text("Dismiss") }
                    .convosButtonStyle(.rounded(fullWidth: true))
            }

            if case .completed = flowState {
            } else if case .syncing = flowState {
            } else if case .failed = flowState {
            } else if case .expired = flowState {
            } else {
                let action = {}
                Button(action: action) { Text("Cancel") }
                    .convosButtonStyle(.text)
                    .frame(maxWidth: .infinity)
            }
        }
    }

    private var stepperBar: some View {
        HStack(spacing: DesignConstants.Spacing.step4x) {
            let backAction = { applyStep(stepIndex - 1) }
            Button(action: backAction) {
                Image(systemName: "chevron.left")
                    .font(.title3.bold())
            }
            .disabled(stepIndex <= 0)

            Spacer()

            VStack(spacing: 2) {
                Text(steps[stepIndex].label)
                    .font(.subheadline.bold())
                    .foregroundStyle(.colorTextPrimary)
                Text("\(stepIndex + 1) of \(steps.count)")
                    .font(.caption)
                    .foregroundStyle(.colorTextTertiary)
            }

            Spacer()

            let forwardAction = { applyStep(stepIndex + 1) }
            Button(action: forwardAction) {
                Image(systemName: "chevron.right")
                    .font(.title3.bold())
            }
            .disabled(stepIndex >= steps.count - 1)
        }
        .padding(.horizontal, DesignConstants.Spacing.step6x)
        .padding(.vertical, DesignConstants.Spacing.step3x)
        .background(.ultraThinMaterial)
    }

    private func applyStep(_ index: Int) {
        let clamped = max(0, min(index, steps.count - 1))
        stepIndex = clamped
        let step = steps[clamped]
        withAnimation(.easeInOut(duration: 0.35)) {
            title = step.title
            flowState = step.state
            secondsRemaining = step.seconds
        }
    }
}

private struct JoinerStep {
    let label: String
    let title: String
    let state: JoinerPairingFlowState
    let seconds: Int
    let pin: String
}

private struct JoinerStepperView: View {
    @State private var stepIndex: Int = 0
    @State private var flowState: JoinerPairingFlowState = .connecting
    @State private var title: String = "Request to pair"
    @State private var secondsRemaining: Int = 54
    @State private var enteredPin: String = ""

    private let steps: [JoinerStep] = [
        .init(label: "Connecting", title: "Request to pair", state: .connecting, seconds: 54, pin: ""),
        .init(label: "Pin Entry (empty)", title: "Request to pair", state: .pinEntry(initiatorInboxId: "abc123"), seconds: 42, pin: ""),
        .init(label: "Pin Entry (filled)", title: "Request to pair", state: .pinEntry(initiatorInboxId: "abc123"), seconds: 38, pin: "482916"),
        .init(label: "Emoji Waiting", title: "Confirm pairing", state: .waitingForEmoji(emojis: ["🦊", "🎸", "🌊"]), seconds: 0, pin: "482916"),
        .init(label: "Syncing", title: "Syncing", state: .syncing, seconds: 0, pin: ""),
        .init(label: "Completed", title: "Device paired", state: .completed, seconds: 0, pin: ""),
        .init(label: "Failed", title: "Request to pair", state: .failed("Connection timed out"), seconds: 0, pin: ""),
        .init(label: "Expired", title: "Request to pair", state: .expired, seconds: 0, pin: ""),
    ]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: DesignConstants.Spacing.step4x) {
                Text(title)
                    .font(.convosTitle)
                    .tracking(Font.convosTitleTracking)
                    .animation(.easeInOut(duration: 0.3), value: title)

                joinerContent
                    .frame(maxWidth: .infinity)
                    .animation(.easeInOut(duration: 0.35), value: flowState)

                joinerButtons
                    .padding(.top, DesignConstants.Spacing.step4x)
                    .animation(.easeInOut(duration: 0.35), value: flowState)
            }
            .padding(.horizontal, DesignConstants.Spacing.step10x)
            .padding(.top, DesignConstants.Spacing.step8x)
            .padding(.bottom, DesignConstants.Spacing.step6x)
        }
        .safeAreaInset(edge: .bottom) {
            stepperBar
        }
        .navigationTitle("Joiner Flow")
        .navigationBarTitleDisplayMode(.inline)
    }

    @ViewBuilder
    private var joinerContent: some View {
        switch flowState {
        case .connecting:
            VStack(spacing: DesignConstants.Spacing.step4x) {
                Text("\"convos-pair-A\" is requesting to pair. Paired devices sync all conversations.")
                    .font(.subheadline)
                    .foregroundStyle(.colorTextPrimary)
                    .frame(maxWidth: .infinity, alignment: .leading)

                ProgressView()
                    .frame(height: 44)

                ExpiryLabel(secondsRemaining: secondsRemaining)
            }
            .transition(.blurReplace)

        case .pinEntry:
            VStack(spacing: DesignConstants.Spacing.step4x) {
                Text("Enter the code shown on \"convos-pair-A\" to finish pairing.")
                    .font(.subheadline)
                    .foregroundStyle(.colorTextPrimary)
                    .frame(maxWidth: .infinity, alignment: .leading)

                DebugPinDisplay(pin: enteredPin)

                ExpiryLabel(secondsRemaining: secondsRemaining)
            }
            .transition(.blurReplace)

        case let .waitingForEmoji(emojis):
            VStack(spacing: DesignConstants.Spacing.step4x) {
                Text("Make sure these emoji match on \"convos-pair-A\".")
                    .font(.subheadline)
                    .foregroundStyle(.colorTextPrimary)
                    .frame(maxWidth: .infinity, alignment: .leading)

                HStack(spacing: DesignConstants.Spacing.step6x) {
                    ForEach(emojis, id: \.self) { emoji in
                        Text(emoji)
                            .font(.system(size: 56))
                    }
                }

                Text("Waiting for confirmation...")
                    .font(.subheadline)
                    .foregroundStyle(.colorTextSecondary)
            }
            .transition(.blurReplace)

        case .syncing:
            VStack(spacing: DesignConstants.Spacing.step4x) {
                RotatingSyncIcon()
                    .frame(width: 64, height: 64)

                Text("Pairing device...")
                    .font(.subheadline)
                    .foregroundStyle(.colorTextSecondary)
            }
            .transition(.blurReplace)

        case .completed:
            VStack(spacing: DesignConstants.Spacing.step4x) {
                Image(systemName: "iphone.badge.checkmark")
                    .font(.system(size: 56))
                    .foregroundStyle(.colorFillPrimary)
                    .symbolRenderingMode(.hierarchical)

                Text("Successfully paired")
                    .font(.subheadline)
                    .foregroundStyle(.colorTextSecondary)
            }
            .transition(.blurReplace)

        case let .failed(message):
            VStack(spacing: DesignConstants.Spacing.step4x) {
                Image(systemName: "exclamationmark.triangle")
                    .font(.system(size: 56))
                    .foregroundStyle(.colorCaution)

                Text(message)
                    .font(.subheadline)
                    .foregroundStyle(.colorTextSecondary)
                    .multilineTextAlignment(.center)
            }
            .transition(.blurReplace)

        case .expired:
            VStack(spacing: DesignConstants.Spacing.step4x) {
                Image(systemName: "clock.badge.xmark")
                    .font(.system(size: 56))
                    .foregroundStyle(.colorTextTertiary)

                Text("Pairing expired. Please try again.")
                    .font(.subheadline)
                    .foregroundStyle(.colorTextSecondary)
                    .multilineTextAlignment(.center)
            }
            .transition(.blurReplace)
        }
    }

    @ViewBuilder
    private var joinerButtons: some View {
        VStack(spacing: DesignConstants.Spacing.step2x) {
            switch flowState {
            case .connecting:
                EmptyView()

            case .pinEntry:
                let action = {}
                Button(action: action) { Text("Submit") }
                    .convosButtonStyle(.rounded(fullWidth: true))
                    .disabled(enteredPin.count < 6)

            case .waitingForEmoji:
                EmptyView()

            case .syncing:
                let action = {}
                Button(action: action) { Text("Pairing...") }
                    .convosButtonStyle(.rounded(fullWidth: true))
                    .disabled(true)

            case .completed:
                let action = {}
                Button(action: action) { Text("Got it") }
                    .convosButtonStyle(.rounded(fullWidth: true))

            case .failed, .expired:
                let action = {}
                Button(action: action) { Text("Dismiss") }
                    .convosButtonStyle(.rounded(fullWidth: true))
            }

            if case .completed = flowState {
            } else if case .syncing = flowState {
            } else if case .failed = flowState {
            } else if case .expired = flowState {
            } else {
                let action = {}
                Button(action: action) { Text("Cancel") }
                    .convosButtonStyle(.text)
                    .frame(maxWidth: .infinity)
            }
        }
    }

    private var stepperBar: some View {
        HStack(spacing: DesignConstants.Spacing.step4x) {
            let backAction = { applyStep(stepIndex - 1) }
            Button(action: backAction) {
                Image(systemName: "chevron.left")
                    .font(.title3.bold())
            }
            .disabled(stepIndex <= 0)

            Spacer()

            VStack(spacing: 2) {
                Text(steps[stepIndex].label)
                    .font(.subheadline.bold())
                    .foregroundStyle(.colorTextPrimary)
                Text("\(stepIndex + 1) of \(steps.count)")
                    .font(.caption)
                    .foregroundStyle(.colorTextTertiary)
            }

            Spacer()

            let forwardAction = { applyStep(stepIndex + 1) }
            Button(action: forwardAction) {
                Image(systemName: "chevron.right")
                    .font(.title3.bold())
            }
            .disabled(stepIndex >= steps.count - 1)
        }
        .padding(.horizontal, DesignConstants.Spacing.step6x)
        .padding(.vertical, DesignConstants.Spacing.step3x)
        .background(.ultraThinMaterial)
    }

    private func applyStep(_ index: Int) {
        let clamped = max(0, min(index, steps.count - 1))
        stepIndex = clamped
        let step = steps[clamped]
        withAnimation(.easeInOut(duration: 0.35)) {
            title = step.title
            flowState = step.state
            secondsRemaining = step.seconds
            enteredPin = step.pin
        }
    }
}

private struct DebugPinDisplay: View {
    let pin: String

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
    }

    private func digitAt(_ index: Int) -> String {
        guard index < pin.count else { return "" }
        return String(pin[pin.index(pin.startIndex, offsetBy: index)])
    }
}

private struct HoldToRevealButton: View {
    @Binding var isHolding: Bool
    @State private var buttonSize: CGSize = .zero

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
    }
}

#Preview("Pairing Flow Debug") {
    NavigationStack {
        PairingFlowDebugView()
    }
}
