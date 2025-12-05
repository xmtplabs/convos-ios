import AVFoundation
import SwiftUI

// swiftlint:disable force_unwrapping

struct JoinConversationView: View {
    @Bindable var viewModel: QRScannerViewModel
    let allowsDismissal: Bool
    let onScannedCode: (String) -> Void

    @State private var showingExplanation: Bool = false

    @Environment(\.dismiss) private var dismiss: DismissAction
    @Environment(\.openURL) private var openURL: OpenURLAction

    var body: some View {
        NavigationStack {
            ZStack {
                QRScannerView(viewModel: viewModel)
                    .ignoresSafeArea()

                let cutoutSize = 240.0
                ZStack {
                    Color.black.opacity(0.8)
                        .ignoresSafeArea()

                    VStack(spacing: DesignConstants.Spacing.stepX) {
                        Spacer()

                        ZStack {
                            RoundedRectangle(cornerRadius: 20)
                                .frame(width: cutoutSize, height: cutoutSize)
                                .blendMode(.destinationOut)
                                .overlay(
                                    RoundedRectangle(cornerRadius: 20)
                                        .stroke(.white, lineWidth: 4)
                                        .frame(width: cutoutSize, height: cutoutSize)
                                )

                            // Show "Enable camera" button when camera is not authorized
                            if !viewModel.cameraAuthorized {
                                Button {
                                    requestCameraAccess()
                                } label: {
                                    HStack(spacing: DesignConstants.Spacing.step2x) {
                                        Image(systemName: "camera.fill")
                                            .font(.callout)
                                            .foregroundStyle(.black)
                                        Text("Allow")
                                            .font(.callout.weight(.medium))
                                            .foregroundStyle(.black)
                                    }
                                    .padding(.vertical, DesignConstants.Spacing.step3x)
                                    .padding(.horizontal, DesignConstants.Spacing.step4x)
                                    .background(
                                        Capsule()
                                            .fill(.white)
                                    )
                                }
                                .frame(width: cutoutSize, height: cutoutSize)
                            }
                        }
                        .padding(.bottom, DesignConstants.Spacing.step3x)

                        VStack(spacing: DesignConstants.Spacing.step3x) {
                            HStack(spacing: DesignConstants.Spacing.step2x) {
                                Image(systemName: "qrcode")
                                    .foregroundStyle(.white)
                                Text("Join a convo by invitation only")
                                    .font(.callout)
                                    .multilineTextAlignment(.center)
                                    .foregroundStyle(.white)
                            }
                            Text("Ask a friend to invite you to a convo, then scan its code or tap its link to enter the app.")
                                .font(.callout)
                                .multilineTextAlignment(.center)
                                .foregroundStyle(.white)
                                .opacity(0.6)
                        }
                        .padding(.horizontal, DesignConstants.Spacing.step10x)

                        Spacer()

                        Group {
                            HStack {
                                Button {
                                    openURL(URL(string: "https://hq.convos.org/privacy-and-terms")!)
                                } label: {
                                    HStack(spacing: DesignConstants.Spacing.stepX) {
                                        Text("Privacy & Terms")
                                        Image(systemName: "chevron.right")
                                            .foregroundStyle(.colorTextTertiary)
                                    }
                                }
                                .font(.caption)
                                .foregroundStyle(.colorTextSecondary)
                                .frame(alignment: .center)

                                Spacer()

                                Button {
                                    if let code = UIPasteboard.general.string {
                                        attemptToScanCode(code)
                                    }
                                } label: {
                                    Image(systemName: "clipboard")
                                        .font(.title3)
                                        .foregroundStyle(.colorTextSecondary)
                                        .padding(.horizontal, DesignConstants.Spacing.step4x)
                                        .padding(.vertical, DesignConstants.Spacing.step3x)
                                }
                                .glassEffect(.regular, in: Circle())
                            }
                        }
                        .padding(.horizontal, DesignConstants.Spacing.step6x)
                        .padding(.vertical, DesignConstants.Spacing.step8x)
                    }
                }
                .compositingGroup()
            }
            .dynamicTypeSize(...DynamicTypeSize.accessibility2)
            .ignoresSafeArea()
            .toolbar {
                if allowsDismissal {
                    ToolbarItem(placement: .topBarLeading) {
                        Button(role: .close) {
                            dismiss()
                        }
                    }
                }
            }
            .alert("This is not a convo", isPresented: $viewModel.showInvalidInviteCodeFormat) {
                Button("Try again") {
                    viewModel.showInvalidInviteCodeFormat = false
                }
                .buttonStyle(.glassProminent)
            } message: {
                if let failedCode = viewModel.invalidInviteCode {
                    Text(failedCode)
                }
            }
        }
        .onChange(of: viewModel.scannedCode) { _, newValue in
            if let code = newValue {
                attemptToScanCode(code)
            }
        }
    }

    private func attemptToScanCode(_ code: String) {
        onScannedCode(code)
    }

    private func requestCameraAccess() {
        let currentStatus = AVCaptureDevice.authorizationStatus(for: .video)

        switch currentStatus {
        case .denied, .restricted:
            // Camera access is denied, direct user to Settings
            if let settingsUrl = URL(string: UIApplication.openSettingsURLString) {
                UIApplication.shared.open(settingsUrl)
            }
        case .notDetermined:
            // Request access for the first time
            viewModel.requestAccess()
        case .authorized:
            // Already authorized (e.g., user came back from Settings)
            // Update the view model state and trigger camera setup
            viewModel.cameraAuthorized = true
            viewModel.triggerCameraSetup()
        @unknown default:
            break
        }
    }
}

// swiftlint:enable force_unwrapping

#Preview {
    JoinConversationView(viewModel: .init(), allowsDismissal: true, onScannedCode: { _ in
    })
}
