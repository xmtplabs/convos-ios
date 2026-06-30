import ConvosCore
import ConvosCoreiOS
import PhotosUI
import SwiftUI
import UIKit

// Entry points into this screen:
// - In an existing conversation: presented over the chat when the user taps
//   "Show an invite code" / the share affordance. `ConversationShareOverlay`
//   wraps this with `mode: .inConvo` and forwards the metrics hook.
// - A brand-new conversation: the first-run / empty convo presents the same
//   wrapper with `mode: .newConvo`; only the captions and nav metadata differ.
//
// The Invite tab renders the stylized QR (`StylizedQRCodeView`) plus a
// "Share invite link" button wired to the conversation invite URL and the
// native share sheet. The Scan tab swaps the QR tile for the live scanner
// viewfinder (`QRScannerView`) and a "Scan a screenshot" button that decodes
// a code picked from the photo library. Both decoded paths feed the same
// `onScannedCode` handler.

/// Variant of the invite-code screen. Mirrors the `ContactCardMode` pattern:
/// the structure is shared; only caption copy and nav metadata branch on the
/// mode.
enum InviteCodeMode {
    /// Presented over an existing conversation.
    case inConvo
    /// Presented for a freshly created conversation (no other members yet).
    case newConvo
}

/// The Scan/Invite toggle screen from the invite design. Owns the segmented
/// control, the Invite (QR + share-link) tab, and the Scan (viewfinder +
/// scan-a-screenshot) tab, plus the floating liquid-glass nav.
struct InviteCodeOverlay: View {
    let conversation: Conversation
    let encodedURLString: String
    let mode: InviteCodeMode
    @Binding var isPresented: Bool
    /// Fired with the decoded payload from either the live viewfinder or a
    /// picked screenshot. Nil keeps the Scan tab in viewfinder-only mode.
    var onScannedCode: ((String) -> Void)?
    /// Forwarded to the share sheet completion so the caller can record a
    /// share metric.
    var onShareCompleted: ((UIActivity.ActivityType?, Bool, Error?) -> Void)?
    /// Tapped on the trailing nav button (`person.crop.circle.badge.plus`).
    /// Nil hides the action.
    var onAddPeople: (() -> Void)?

    @State private var selection: ScanInviteSegment = .invite
    @State private var conversationImage: UIImage?
    @State private var isShareSheetPresented: Bool = false
    @State private var scannerViewModel: QRScannerViewModel = QRScannerViewModel()
    @State private var selectedScreenshot: PhotosPickerItem?
    @State private var isDecodingScreenshot: Bool = false

    @Environment(\.safeAreaInsets) private var safeAreaInsets: EdgeInsets

    var body: some View {
        ZStack {
            backdrop
            VStack(spacing: 0.0) {
                contentColumn
                Spacer(minLength: 0.0)
            }
            .padding(.top, safeAreaInsets.top + Constant.navHeight + DesignConstants.Spacing.step8x)
            floatingNav
        }
        .background(.colorBackgroundSurfaceless)
        .ignoresSafeArea()
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
    }

    private var backdrop: some View {
        Color.colorBackgroundSurfaceless
            .ignoresSafeArea()
    }

    // MARK: - Content column

    private var contentColumn: some View {
        VStack(spacing: DesignConstants.Spacing.step4x) {
            ScanInviteToggle(selection: $selection)
            tileView
            actionButton
            captionBlock
        }
        .frame(width: Constant.columnWidth)
    }

    @ViewBuilder
    private var tileView: some View {
        switch selection {
        case .invite:
            StylizedQRCodeView(
                encodedURLString: encodedURLString,
                centerImage: conversationImage,
                tileSize: Constant.tileSize
            )
        case .scan:
            viewfinderTile
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

    // MARK: - Floating nav

    private var floatingNav: some View {
        VStack {
            HStack(alignment: .center) {
                navCircleButton(icon: "chevron.backward", action: dismiss)
                    .accessibilityLabel("Back")
                Spacer(minLength: DesignConstants.Spacing.step2x)
                navTitleChip
                Spacer(minLength: DesignConstants.Spacing.step2x)
                if let onAddPeople {
                    navCircleButton(icon: "person.crop.circle.badge.plus", action: onAddPeople)
                        .accessibilityLabel("Add people")
                } else {
                    Color.clear.frame(width: Constant.navButtonSize, height: Constant.navButtonSize)
                }
            }
            .padding(.horizontal, DesignConstants.Spacing.step4x)
            .padding(.top, safeAreaInsets.top + DesignConstants.Spacing.step3x)
            Spacer()
        }
    }

    private func navCircleButton(icon: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.body.weight(.medium))
                .foregroundStyle(.colorTextPrimary)
                .frame(width: Constant.navButtonSize, height: Constant.navButtonSize)
                .glassEffect(.regular.interactive(), in: .circle)
        }
        .buttonStyle(.plain)
    }

    private var navTitleChip: some View {
        HStack(spacing: DesignConstants.Spacing.step2x) {
            ConversationAvatarView(conversation: conversation, conversationImage: conversationImage, size: Constant.navAvatarSize)
                .frame(width: Constant.navAvatarSize, height: Constant.navAvatarSize)
            VStack(alignment: .leading, spacing: 0.0) {
                Text(conversation.displayName)
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(.colorTextPrimary)
                Text(navSubtitle)
                    .font(.caption)
                    .foregroundStyle(.colorTextSecondary)
            }
            .lineLimit(1)
        }
        .padding(DesignConstants.Spacing.step2x)
        .glassEffect(.regular.interactive(), in: .capsule)
        .accessibilityIdentifier("invite-nav-title-chip")
    }

    private var navSubtitle: String {
        let others: Int = conversation.membersWithoutCurrent.count
        switch mode {
        case .newConvo where others == 0:
            return "Just you"
        default:
            let total: Int = others + 1
            return total == 1 ? "Just you" : "\(total) members"
        }
    }

    // MARK: - Actions

    private func presentShareSheet() {
        isShareSheetPresented = true
    }

    private func dismiss() {
        isPresented = false
    }

    private func handleScannedCode(_ code: String?) {
        guard let code, let onScannedCode else { return }
        onScannedCode(code)
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
        static let navHeight: CGFloat = 44.0
        static let navButtonSize: CGFloat = 44.0
        static let navAvatarSize: CGFloat = 36.0
    }
}

#Preview {
    @Previewable @State var isPresented: Bool = true
    InviteCodeOverlay(
        conversation: .mock(),
        encodedURLString: "https://local.convos.org/v2?i=preview-invite-token",
        mode: .inConvo,
        isPresented: $isPresented
    )
    .withSafeAreaEnvironment()
}
