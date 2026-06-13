import AVFoundation
import SwiftUI

struct JoinConversationView: View {
    @Bindable var viewModel: QRScannerViewModel
    let allowsDismissal: Bool
    let onScannedCode: (String) -> Void

    @State private var showingExplanation: Bool = false

    @Environment(\.dismiss) private var dismiss: DismissAction

    var body: some View {
        NavigationStack {
            scannerStack
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
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        if let code = UIPasteboard.general.string {
                            attemptToScanCode(code)
                        }
                    } label: {
                        Image(systemName: "clipboard")
                    }
                    .accessibilityLabel("Paste invite code from clipboard")
                    .accessibilityIdentifier("paste-invite-button")
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

    private var scannerStack: some View {
        ZStack {
            QRScannerView(viewModel: viewModel)
                .ignoresSafeArea()
            scannerOverlay
        }
    }

    private var scannerOverlay: some View {
        let cutoutSize = 240.0
        return ZStack {
            Color.black.opacity(0.8)
                .ignoresSafeArea()

            VStack(spacing: DesignConstants.Spacing.stepX) {
                Spacer()
                cutout(size: cutoutSize)
                    .padding(.bottom, DesignConstants.Spacing.step3x)
                scannerCaption
                Spacer()
            }
        }
        .compositingGroup()
    }

    @ViewBuilder
    private func cutout(size: CGFloat) -> some View {
        ZStack {
            RoundedRectangle(cornerRadius: 20)
                .frame(width: size, height: size)
                .blendMode(.destinationOut)
                .overlay(
                    RoundedRectangle(cornerRadius: 20)
                        .stroke(.white, lineWidth: 4)
                        .frame(width: size, height: size)
                )

            if !viewModel.cameraAuthorized {
                Button {
                    requestCameraAccess()
                } label: {
                    HStack(spacing: DesignConstants.Spacing.step2x) {
                        Image(systemName: "viewfinder")
                            .font(.callout)
                            .foregroundStyle(.black)
                        Text("Scan")
                            .font(.callout.weight(.medium))
                            .foregroundStyle(.black)
                    }
                    .padding(.vertical, DesignConstants.Spacing.step3x)
                    .padding(.horizontal, DesignConstants.Spacing.step4x)
                    .background(Capsule().fill(.white))
                }
                .frame(width: size, height: size)
            }
        }
    }

    private var scannerCaption: some View {
        HStack(spacing: DesignConstants.Spacing.step2x) {
            Image(systemName: "qrcode")
                .foregroundStyle(.white)
            Text("Scan a convo code")
                .font(.callout)
                .multilineTextAlignment(.center)
                .foregroundStyle(.white)
        }
        .padding(.horizontal, DesignConstants.Spacing.step10x)
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

#Preview {
    JoinConversationView(viewModel: .init(), allowsDismissal: true, onScannedCode: { _ in
    })
}
