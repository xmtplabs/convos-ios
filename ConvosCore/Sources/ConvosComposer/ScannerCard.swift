#if canImport(UIKit)
import AVFoundation
import ConvosCore
import PhotosUI
import SwiftUI
import UIKit

/// Reading someone else's code: a live viewfinder, a "Scan a screenshot"
/// affordance for a code that arrived as an image, and a line saying what a
/// scan does. Sized and styled as the same column `InviteCodeCard` uses, so
/// the two screens read as a pair.
public struct ScannerCard: View {
    /// Fired with the decoded payload from either the live viewfinder or a
    /// picked screenshot.
    var onScannedCode: (String) -> Void

    @State private var scannerViewModel: QRScannerViewModel = QRScannerViewModel()
    @State private var selectedScreenshot: PhotosPickerItem?
    @State private var isDecodingScreenshot: Bool = false

    public init(onScannedCode: @escaping (String) -> Void) {
        self.onScannedCode = onScannedCode
    }

    public var body: some View {
        VStack(spacing: DesignConstants.Spacing.step4x) {
            viewfinderTile
            screenshotPickerButton
            captionBlock
        }
        .frame(width: Constant.columnWidth)
        .onChange(of: scannerViewModel.scannedCode) { _, newValue in
            handleScannedCode(newValue)
        }
        .onChange(of: selectedScreenshot) { _, newValue in
            handleSelectedScreenshot(newValue)
        }
        .onAppear {
            requestCameraAccessIfNeeded()
        }
    }

    private var viewfinderTile: some View {
        QRScannerView(viewModel: scannerViewModel)
            .frame(width: Constant.tileSize, height: Constant.tileSize)
            .clipShape(RoundedRectangle(cornerRadius: DesignConstants.CornerRadius.extraLarge))
            .overlay(
                RoundedRectangle(cornerRadius: DesignConstants.CornerRadius.extraLarge)
                    .stroke(.black.opacity(0.3), lineWidth: 1.0)
            )
            .accessibilityIdentifier("invite-scan-viewfinder")
    }

    /// The affordance is the `PhotosPicker` itself, styled as the tile.
    /// Wrapping a transparent picker over a separate `Button` left the button
    /// intercepting the tap, so the picker never opened; making the picker the
    /// whole control guarantees the tap presents the library.
    private var screenshotPickerButton: some View {
        PhotosPicker(
            selection: $selectedScreenshot,
            matching: .images,
            photoLibrary: .shared()
        ) {
            HStack(spacing: DesignConstants.Spacing.step2x) {
                Image(systemName: "photo.fill")
                Text("Scan a screenshot")
                    .font(.callout)
            }
            .foregroundStyle(.colorTextPrimary)
            .frame(maxWidth: .infinity)
            .frame(height: Constant.buttonHeight)
            .background(
                RoundedRectangle(cornerRadius: DesignConstants.CornerRadius.large)
                    .fill(DesignConstants.Colors.fillSubtle)
            )
        }
        .accessibilityIdentifier("scan-a-screenshot-button")
        .accessibilityLabel("Scan a screenshot")
    }

    private var captionBlock: some View {
        VStack(spacing: DesignConstants.Spacing.stepX) {
            Text("Scan to invite an agent or join a new convo")
                .font(.footnote)
                .foregroundStyle(.colorTextPrimary)
            Text("New member will be added to your Contacts")
                .font(.caption)
                .foregroundStyle(.colorTextSecondary)
        }
        .multilineTextAlignment(.center)
    }

    /// Without this, `QRScannerView.checkCameraAuthorization` maps a
    /// `.notDetermined` status to "not authorized" and skips camera setup, so
    /// a first-time user gets a black viewfinder and no permission prompt.
    private func requestCameraAccessIfNeeded() {
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .notDetermined:
            scannerViewModel.requestAccess()
        case .authorized:
            scannerViewModel.cameraAuthorized = true
            scannerViewModel.triggerCameraSetup()
        default:
            break
        }
    }

    private func handleScannedCode(_ code: String?) {
        guard let code else { return }
        onScannedCode(code)
        // A scan disables further scanning. A recognized code hands off to a
        // join flow, so re-arming would let the camera - still aimed at the
        // same QR - fire a duplicate once the interval elapses. Re-arm only
        // for an unrecognized payload, so someone who scanned the wrong thing
        // can line up a real code straight away.
        guard !isRecognizedInviteCode(code) else { return }
        scannerViewModel.resetScanning()
    }

    private func isRecognizedInviteCode(_ code: String) -> Bool {
        if InviteURLDetector.detectInviteURL(in: code) != nil {
            return true
        }
        guard let url = URL(string: code) else { return false }
        return DeepLinkHandler.agentTemplateId(from: url) != nil
    }

    private func handleSelectedScreenshot(_ item: PhotosPickerItem?) {
        guard let item, !isDecodingScreenshot else { return }
        isDecodingScreenshot = true
        Task {
            defer {
                isDecodingScreenshot = false
                selectedScreenshot = nil
            }
            guard let data = try? await item.loadTransferable(type: Data.self),
                  let image = UIImage(data: data),
                  let decoded = await QRImageDecoder.decode(image) else { return }
            handleScannedCode(decoded)
        }
    }

    private enum Constant {
        static let columnWidth: CGFloat = 283.0
        static let tileSize: CGFloat = 280.0
        static let buttonHeight: CGFloat = 72.0
    }
}

#Preview {
    ScannerCard(onScannedCode: { _ in })
}
#endif
