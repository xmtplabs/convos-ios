import ConvosCore
import ConvosCoreiOS
import SwiftUI

struct ConversationShareOverlay: View {
    let conversation: Conversation
    let invite: Invite
    @Binding var isPresented: Bool
    let topSafeAreaInset: CGFloat

    @State private var showCard: Bool = false
    @State private var isShareSheetPresented: Bool = false
    @State private var conversationImage: Image = Image("convosIcon")
    @State private var qrCodeImage: UIImage?
    @Environment(\.displayScale) private var displayScale: CGFloat

    private static let headerHeight: CGFloat = 40.0
    private static let cardPadding: CGFloat = 40.0
    private static let maxQRSize: CGFloat = 220.0
    private static let shareSheetFraction: CGFloat = 0.45

    private var qrDisplaySize: CGFloat {
        let screenHeight = UIScreen.main.bounds.height
        let availableHeight = screenHeight * (1.0 - Self.shareSheetFraction)
            - topSafeAreaInset
            - DesignConstants.Spacing.step4x
            - Self.headerHeight
            - Self.cardPadding
            - DesignConstants.Spacing.step10x
        let availableWidth = UIScreen.main.bounds.width
            - DesignConstants.Spacing.step10x * 2
            - Self.cardPadding * 2
        let maxFit = min(availableHeight, availableWidth)
        return min(max(maxFit, 120.0), Self.maxQRSize)
    }

    var body: some View {
        ZStack {
            if showCard {
                Color.black.opacity(0.5)
                    .background(.ultraThinMaterial)
                    .ignoresSafeArea()
                    .transition(.opacity)
                    .onTapGesture {
                        dismissFlow()
                    }
            }

            if showCard {
                VStack(spacing: 0.0) {
                    convoCodeCard(qrSize: qrDisplaySize)

                    Spacer()
                }
                .padding(.top, topSafeAreaInset + DesignConstants.Spacing.step4x)
                .transition(
                    .asymmetric(
                        insertion: .move(edge: .top).combined(with: .opacity),
                        removal: .opacity
                    )
                )
            }

            Color.clear
                .frame(width: 1, height: 1)
                .background(
                    ShareSheetPresenter(
                        activityItems: [invite.inviteURLString],
                        isPresented: $isShareSheetPresented,
                        onDismiss: {
                            dismissFlow()
                        }
                    )
                )
        }
        .cachedImage(for: conversation) { image in
            if let image {
                conversationImage = Image(uiImage: image)
            }
        }
        .task {
            guard let inviteURL = invite.inviteURL else { return }
            let options = QRCodeGenerator.Options(
                scale: displayScale,
                displaySize: Self.maxQRSize,
                foregroundColor: UIColor(.colorTextPrimary),
                backgroundColor: UIColor(.colorBackgroundSurfaceless)
            )
            let generated = await QRCodeGenerator.generate(from: inviteURL.absoluteString, options: options)
            guard !Task.isCancelled else { return }
            qrCodeImage = generated

            withAnimation(.spring(response: 0.5, dampingFraction: 0.78)) {
                showCard = true
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
                isShareSheetPresented = true
            }
        }
    }

    private func convoCodeCard(qrSize: CGFloat) -> some View {
        let centerImageSize: CGFloat = qrSize * (50.0 / Self.maxQRSize)
        let centerBackgroundSize: CGFloat = qrSize * (55.0 / Self.maxQRSize)
        let cardInternalPadding: CGFloat = qrSize * (Self.cardPadding / Self.maxQRSize)

        return VStack(spacing: 0.0) {
            HStack(alignment: .center) {
                Text("Convos code")
                    .kerning(1.0)

                Image("convosIcon")
                    .renderingMode(.template)
                    .resizable()
                    .frame(width: 14.0, height: 14.0)
                    .foregroundStyle(.colorFillTertiary)

                Text("Scan to join")
                    .kerning(1.0)
            }
            .offset(y: 5.0)
            .foregroundStyle(.colorTextSecondary)
            .textCase(.uppercase)
            .font(.caption)
            .frame(height: Self.headerHeight)

            if let qrCodeImage {
                ZStack {
                    Image(uiImage: qrCodeImage)
                        .resizable()
                        .aspectRatio(1.0, contentMode: .fit)
                        .frame(width: qrSize, height: qrSize)

                    ZStack {
                        Rectangle()
                            .fill(.colorBackgroundSurfaceless)
                            .frame(width: centerBackgroundSize, height: centerBackgroundSize)

                        ZStack {
                            Rectangle()
                                .fill(.colorTextPrimary)
                            conversationImage
                                .resizable()
                                .aspectRatio(contentMode: .fill)
                        }
                        .frame(width: centerImageSize, height: centerImageSize)
                        .clipShape(RoundedRectangle(cornerRadius: DesignConstants.CornerRadius.small))
                    }
                }
                .padding([.leading, .trailing, .bottom], cardInternalPadding)
                .accessibilityLabel("Share QR code for conversation invite")
                .accessibilityIdentifier("share-qr-code")
            }
        }
        .background(.white)
        .clipShape(RoundedRectangle(cornerRadius: DesignConstants.CornerRadius.large))
        .padding(.horizontal, DesignConstants.Spacing.step10x)
    }

    private func dismissFlow() {
        withAnimation(.easeOut(duration: 0.25)) {
            showCard = false
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
            isPresented = false
        }
    }
}

private struct ShareSheetPresenter: UIViewControllerRepresentable {
    let activityItems: [Any]
    @Binding var isPresented: Bool
    let onDismiss: () -> Void

    func makeUIViewController(context: Context) -> UIViewController {
        UIViewController()
    }

    func updateUIViewController(_ uiViewController: UIViewController, context: Context) {
        if isPresented && uiViewController.presentedViewController == nil {
            let activityVC = UIActivityViewController(
                activityItems: activityItems,
                applicationActivities: nil
            )

            if let popover = activityVC.popoverPresentationController {
                popover.sourceView = uiViewController.view
                popover.sourceRect = CGRect(
                    x: uiViewController.view.bounds.midX,
                    y: uiViewController.view.bounds.midY,
                    width: 0,
                    height: 0
                )
                popover.permittedArrowDirections = []
            }

            activityVC.completionWithItemsHandler = { _, _, _, _ in
                isPresented = false
                onDismiss()
            }

            uiViewController.present(activityVC, animated: true)
        }
    }
}

#Preview {
    @Previewable @State var isPresented: Bool = true
    ZStack {
        Color.gray.ignoresSafeArea()
        Text("Conversation Content")

        if isPresented {
            ConversationShareOverlay(
                conversation: .mock(),
                invite: .mock(),
                isPresented: $isPresented,
                topSafeAreaInset: 59.0
            )
        }
    }
}
