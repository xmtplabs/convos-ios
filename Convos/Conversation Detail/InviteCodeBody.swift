import AVFoundation
import ConvosCore
import ConvosCoreiOS
import PhotosUI
import SwiftUI
import UIKit

// The embeddable core of the invite-code screen: the Scan/Invite segmented
// toggle plus its two tabs (Invite = legacy QR card + "Share invite link";
// Scan = live viewfinder + "Scan a screenshot"), without any full-screen nav
// chrome. `InviteCodeOverlay` composes this under its floating liquid-glass
// nav for the full-screen flow; `ConversationView` embeds it via a top
// `safeAreaInset` when a "Show an invite code" convo owns the QR inline. Both
// share this single implementation so the toggle + tabs don't fork.

/// The toggle + Invite/Scan tabs, sized to a fixed column. Owns the segment
/// selection, QR generation, the live scanner, and the screenshot-picker
/// decode path. Decoded codes (viewfinder or picked screenshot) feed
/// `onScannedCode`; nil keeps the Scan tab viewfinder-only.
struct InviteCodeBody: View {
    let conversation: Conversation
    let encodedURLString: String
    let mode: InviteCodeMode
    /// Segment selected when the body first appears.
    var initialSegment: ScanInviteSegment = .invite
    /// Fired with the decoded payload from either the live viewfinder or a
    /// picked screenshot.
    var onScannedCode: ((String) -> Void)?
    /// Forwarded to the share sheet completion so the caller can record a
    /// share metric.
    var onShareCompleted: ((UIActivity.ActivityType?, Bool, Error?) -> Void)?

    @State private var selection: ScanInviteSegment
    @State private var conversationImage: UIImage?
    @State private var isShareSheetPresented: Bool = false
    @State private var scannerViewModel: QRScannerViewModel = QRScannerViewModel()
    @State private var selectedScreenshot: PhotosPickerItem?
    @State private var isDecodingScreenshot: Bool = false
    @State private var qrImage: UIImage?

    @Environment(\.displayScale) private var displayScale: CGFloat

    init(
        conversation: Conversation,
        encodedURLString: String,
        mode: InviteCodeMode,
        initialSegment: ScanInviteSegment = .invite,
        onScannedCode: ((String) -> Void)? = nil,
        onShareCompleted: ((UIActivity.ActivityType?, Bool, Error?) -> Void)? = nil
    ) {
        self.conversation = conversation
        self.encodedURLString = encodedURLString
        self.mode = mode
        self.initialSegment = initialSegment
        self.onScannedCode = onScannedCode
        self.onShareCompleted = onShareCompleted
        _selection = State(initialValue: initialSegment)
    }

    var body: some View {
        VStack(spacing: DesignConstants.Spacing.step4x) {
            ScanInviteToggle(selection: $selection)
            tileView
            actionButton
            captionBlock
        }
        .frame(width: Constant.columnWidth)
        .cachedImage(for: conversation, into: $conversationImage)
        .shareSheet(
            isPresented: $isShareSheetPresented,
            items: [encodedURLString],
            onCompletion: onShareCompleted
        )
        .onChange(of: scannerViewModel.scannedCode) { _, newValue in
            handleScannedCode(newValue)
        }
        .onChange(of: selectedScreenshot) { _, newValue in
            handleSelectedScreenshot(newValue)
        }
        .onChange(of: selection) { _, newValue in
            handleSelectionChanged(to: newValue)
        }
        .onAppear {
            handleSelectionChanged(to: selection)
        }
    }

    /// Requests camera access the moment the Scan segment becomes active.
    /// Without this, `QRScannerView.checkCameraAuthorization` maps a
    /// `.notDetermined` status to "not authorized" and skips camera setup, so
    /// a first-time user gets a black viewfinder and no permission prompt.
    /// Mirrors `JoinConversationView.requestCameraAccess`.
    private func handleSelectionChanged(to newValue: ScanInviteSegment) {
        guard newValue == .scan else { return }
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

    @ViewBuilder
    private var tileView: some View {
        switch selection {
        case .invite:
            inviteQRTile
        case .scan:
            viewfinderTile
        }
    }

    /// The Figma QR card (nodes 1/2): the `fillSubtle` rounded card (corner
    /// radius `.extraLarge` = 56), generously padded from the card edge, with
    /// the legacy `QRCodeGenerator` glyph (rounded modules, Q error correction,
    /// a 0.25 center hole) and the conversation avatar overlaid into the center
    /// circle. The card and screens are Figma; the glyph itself is the one
    /// legacy element. The generator leaves a center hole; `ConversationAvatarView`
    /// fills it and provides the avatar -> emoji -> monogram fallback so the
    /// center is never empty.
    private var inviteQRTile: some View {
        let cardSize: CGFloat = Constant.tileSize
        let qrSize: CGFloat = cardSize - Constant.qrCardPadding * 2.0
        let centerDiameter: CGFloat = qrSize * Constant.qrCenterFraction
        // The generator clears a square region in the QR matrix (centerSpaceSize),
        // whose corners read as a square frame around the round avatar. A circular
        // fillSubtle disc sized to the square's diagonal hides those corners so the
        // eye only sees a clean circle. sqrt(2) covers the corners of the cleared
        // square (side == centerDiameter) without enlarging the cleared area.
        let centerDiscDiameter: CGFloat = centerDiameter * 1.4142135623730951
        return ZStack {
            RoundedRectangle(cornerRadius: DesignConstants.CornerRadius.extraLarge)
                .fill(DesignConstants.Colors.fillSubtle)
            if let qrImage {
                Image(uiImage: qrImage)
                    .resizable()
                    .interpolation(.none)
                    .aspectRatio(1.0, contentMode: .fit)
                    .frame(width: qrSize, height: qrSize)
                    .transition(.opacity)
            }
            Circle()
                .fill(DesignConstants.Colors.fillSubtle)
                .frame(width: centerDiscDiameter, height: centerDiscDiameter)
            ConversationAvatarView(
                conversation: conversation,
                conversationImage: conversationImage,
                size: centerDiameter
            )
            .frame(width: centerDiameter, height: centerDiameter)
            .clipShape(.circle)
        }
        .frame(width: cardSize, height: cardSize)
        .task(id: qrTaskKey) {
            await regenerateQR(size: qrSize)
        }
        .accessibilityElement()
        .accessibilityLabel("Invite QR code")
        .accessibilityIdentifier("invite-qr-code-view")
    }

    private var qrTaskKey: String {
        "\(encodedURLString)|\(displayScale)"
    }

    private func regenerateQR(size: CGFloat) async {
        let options = QRCodeGenerator.Options(
            scale: displayScale,
            displaySize: size,
            foregroundColor: UIColor(.colorTextPrimary),
            backgroundColor: UIColor(DesignConstants.Colors.fillSubtle)
        )
        let generated = await QRCodeGenerator.generate(from: encodedURLString, options: options)
        guard !Task.isCancelled else { return }
        withAnimation(.easeInOut(duration: 0.2)) {
            qrImage = generated
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

    @ViewBuilder
    private var actionButton: some View {
        switch selection {
        case .invite:
            tileButton(icon: "square.and.arrow.up", title: "Share invite link", action: presentShareSheet)
                .accessibilityIdentifier("share-invite-link-button")
        case .scan:
            tileButton(icon: "photo.fill", title: "Scan a screenshot", action: {})
                .accessibilityIdentifier("scan-a-screenshot-button")
                .overlay(screenshotPickerOverlay)
        }
    }

    /// A transparent `PhotosPicker` stacked over the "Scan a screenshot"
    /// button so the styled button stays the visible affordance while the
    /// picker captures the tap.
    private var screenshotPickerOverlay: some View {
        PhotosPicker(
            selection: $selectedScreenshot,
            matching: .images,
            photoLibrary: .shared()
        ) {
            Color.clear
        }
        .accessibilityLabel("Scan a screenshot")
    }

    private func tileButton(icon: String, title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: DesignConstants.Spacing.step2x) {
                Image(systemName: icon)
                Text(title)
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
        .buttonStyle(.plain)
    }

    private var captionBlock: some View {
        VStack(spacing: DesignConstants.Spacing.stepX) {
            Text(captionPrimary)
                .font(.footnote)
                .foregroundStyle(.colorTextPrimary)
            Text(captionSecondary)
                .font(.caption)
                .foregroundStyle(.colorTextSecondary)
        }
        .multilineTextAlignment(.center)
    }

    private var captionPrimary: String {
        switch selection {
        case .invite: return "Invite people to this convo by sharing this code"
        case .scan: return "Scan to invite an agent or join a new convo"
        }
    }

    private var captionSecondary: String {
        switch selection {
        case .invite: return "They'll be added to your Contacts"
        case .scan: return "New member will be added to your Contacts"
        }
    }

    // MARK: - Actions

    private func presentShareSheet() {
        isShareSheetPresented = true
    }

    private func handleScannedCode(_ code: String?) {
        guard let code, let onScannedCode else { return }
        onScannedCode(code)
        // A scan disables further scanning (`isScanningEnabled = false`); without
        // re-enabling, the viewfinder goes dead after one code -- including after
        // a rejected/invalid code. Re-arm so repeated scans keep working. The
        // 3s minimum-scan-interval in the VM still debounces duplicates.
        scannerViewModel.resetScanning()
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
        /// Padding from the card edge to the QR glyph, giving the roomy
        /// QR-to-card spacing from the Figma card.
        static let qrCardPadding: CGFloat = 32.0
        /// Center-avatar diameter as a fraction of the QR, sized to land in
        /// the generator's 0.25 center hole.
        static let qrCenterFraction: CGFloat = 0.25
        static let buttonHeight: CGFloat = 72.0
    }
}

#Preview {
    InviteCodeBody(
        conversation: .mock(),
        encodedURLString: "https://local.convos.org/v2?i=preview-invite-token",
        mode: .inConvo
    )
}
