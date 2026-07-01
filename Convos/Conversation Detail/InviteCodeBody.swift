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
    @Environment(\.colorScheme) private var colorScheme: ColorScheme

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
    /// the legacy `QRCodeGenerator` glyph (rounded modules, Q error correction)
    /// and the conversation avatar overlaid into the center circle. The card and
    /// screens are Figma; the glyph itself is the one legacy element. The
    /// generator clears a square center; a circular hole mask rounds that gap so
    /// the cleared center is a clean circle, into which the standard
    /// `ConversationAvatarView` (the same disc + emoji/photo styling the
    /// conversation list uses) is dropped so the center matches the list avatar.
    private var inviteQRTile: some View {
        let cardSize: CGFloat = Constant.tileSize
        let qrSize: CGFloat = cardSize - Constant.qrCardPadding * 2.0
        let centerDiameter: CGFloat = qrSize * Constant.qrCenterFraction
        // The generator clears a square region in the QR matrix (centerSpaceSize),
        // whose corners read as a square frame around the round avatar. Punch a
        // circular hole out of the QR image sized to the square's diagonal so the
        // cleared center is a clean circle. The avatar fills that circle (same as
        // the list avatar filling its row circle). sqrt(2) reaches the corners of
        // the cleared square (side == centerDiameter) without enlarging it.
        let centerHoleDiameter: CGFloat = centerDiameter * 1.4142135623730951
        return ZStack {
            RoundedRectangle(cornerRadius: DesignConstants.CornerRadius.extraLarge)
                .fill(DesignConstants.Colors.fillSubtle)
            if let qrImage {
                Image(uiImage: qrImage)
                    .resizable()
                    .interpolation(.none)
                    .aspectRatio(1.0, contentMode: .fit)
                    .frame(width: qrSize, height: qrSize)
                    .mask(qrCenterMask(holeDiameter: centerHoleDiameter))
                    .transition(.opacity)
            }
            ConversationAvatarView(
                conversation: conversation,
                conversationImage: conversationImage,
                size: centerHoleDiameter
            )
            .frame(width: centerHoleDiameter, height: centerHoleDiameter)
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

    /// Full-square mask with a centered circular hole, used to round off the
    /// corners of the generator's square cleared center so the avatar sits in a
    /// clean circular hole (no square frame) rather than a square one.
    private func qrCenterMask(holeDiameter: CGFloat) -> some View {
        Rectangle()
            .overlay(
                Circle()
                    .frame(width: holeDiameter, height: holeDiameter)
                    .blendMode(.destinationOut)
            )
            .compositingGroup()
    }

    private var qrTaskKey: String {
        "\(encodedURLString)|\(displayScale)|\(colorScheme)"
    }

    private func regenerateQR(size: CGFloat) async {
        let options = QRCodeGenerator.Options(
            scale: displayScale,
            displaySize: size,
            centerSpaceSize: Float(Constant.qrCenterFraction),
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
            let action = presentShareSheet
            Button(action: action) {
                TileLabel(icon: "square.and.arrow.up", title: "Share invite link")
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("share-invite-link-button")
        case .scan:
            screenshotPickerButton
        }
    }

    /// The "Scan a screenshot" affordance is the `PhotosPicker` itself, styled
    /// as the tile. Wrapping a transparent picker over a separate `Button`
    /// left the button intercepting the tap, so the picker never opened; making
    /// the picker the whole control guarantees the tap presents the library.
    private var screenshotPickerButton: some View {
        PhotosPicker(
            selection: $selectedScreenshot,
            matching: .images,
            photoLibrary: .shared()
        ) {
            TileLabel(icon: "photo.fill", title: "Scan a screenshot")
        }
        .accessibilityIdentifier("scan-a-screenshot-button")
        .accessibilityLabel("Scan a screenshot")
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
        // A scan disables further scanning (`isScanningEnabled = false`). A
        // recognized invite/agent code hands off to a navigation/join flow, so
        // re-arming here would let the camera -- still aimed at the same QR --
        // fire a duplicate scan once the 3s interval elapses, stacking a second
        // join flow on the first. Re-arm only for an unrecognized payload so a
        // user who scanned the wrong thing can immediately line up a real code.
        guard !isRecognizedInviteCode(code) else { return }
        scannerViewModel.resetScanning()
    }

    /// Whether a scanned payload is a Convos invite or agent-template code the
    /// scan handler will act on. Used to decide whether re-arming the
    /// viewfinder after a scan is safe (see `handleScannedCode`).
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

    /// The shared styled tile used by both action affordances. A standalone
    /// `View` (not a method) so the `PhotosPicker` label closure -- which is
    /// nonisolated -- can build it without hopping the main actor.
    private struct TileLabel: View {
        let icon: String
        let title: String

        var body: some View {
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
    }

    private enum Constant {
        static let columnWidth: CGFloat = 283.0
        static let tileSize: CGFloat = 280.0
        /// Padding from the card edge to the QR glyph, giving the roomy
        /// QR-to-card spacing from the Figma card.
        static let qrCardPadding: CGFloat = 32.0
        /// Center-avatar diameter as a fraction of the QR. Also drives the
        /// generator's cleared center (`centerSpaceSize`) and the circular hole
        /// mask, which are kept locked to this value so the avatar exactly fills
        /// the cleared circle. 0.28 is the largest center that still reliably
        /// decodes a short real invite under Q error correction (verified with
        /// Vision against the rendered output, occlusion worst-cased); longer
        /// real invites carry more margin.
        static let qrCenterFraction: CGFloat = 0.28
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
