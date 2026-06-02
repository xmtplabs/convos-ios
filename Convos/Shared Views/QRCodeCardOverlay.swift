import ConvosCore
import ConvosCoreiOS
import SwiftUI

/// Reusable "code card" overlay: a QR card animates down from the top with a
/// custom header and center chip, and the native share sheet presents behind
/// it. Used by the conversation "Convos code" share flow and the agent
/// contact card's share action. Callers supply the encoded URL (used for both
/// the QR and the share item), the header content, and the QR center chip.
/// The overlay applies the shared uppercase-caption styling to `header`.
struct QRCodeCardOverlay<Header: View, Center: View>: View {
    let encodedURLString: String
    @Binding var isPresented: Bool
    let topSafeAreaInset: CGFloat
    @ViewBuilder let header: () -> Header
    @ViewBuilder let center: () -> Center

    @State private var showCard: Bool = false
    @State private var isShareSheetPresented: Bool = false
    @State private var qrCodeImage: UIImage?
    /// Defers presenting the share sheet until the card has animated in.
    /// Tracked so dismissing during the gap cancels the pending present.
    @State private var sharePresentTask: Task<Void, Never>?
    @Environment(\.displayScale) private var displayScale: CGFloat

    private static var headerHeight: CGFloat { 40.0 }
    private static var cardPadding: CGFloat { 40.0 }
    private static var maxQRSize: CGFloat { 220.0 }
    private static var shareSheetFraction: CGFloat { 0.55 }

    private func qrDisplaySize(in size: CGSize) -> CGFloat {
        let availableHeight = size.height * (1.0 - Self.shareSheetFraction)
            - topSafeAreaInset
            - DesignConstants.Spacing.step4x
            - Self.headerHeight
            - Self.cardPadding
            - DesignConstants.Spacing.step10x
        let availableWidth = size.width
            - DesignConstants.Spacing.step10x * 2
            - Self.cardPadding * 2
        let maxFit = min(availableHeight, availableWidth)
        return min(max(maxFit, 120.0), Self.maxQRSize)
    }

    var body: some View {
        GeometryReader { geometry in
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
                        codeCard(qrSize: qrDisplaySize(in: geometry.size))
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
                    .shareSheet(
                        isPresented: $isShareSheetPresented,
                        items: [encodedURLString],
                        onDismiss: {
                            dismissFlow()
                        }
                    )
            }
            .task {
                let options = QRCodeGenerator.Options(
                    scale: displayScale,
                    displaySize: Self.maxQRSize,
                    foregroundColor: UIColor(.colorTextPrimary),
                    backgroundColor: UIColor(.colorBackgroundSurfaceless)
                )
                let generated = await QRCodeGenerator.generate(from: encodedURLString, options: options)
                guard !Task.isCancelled else { return }
                qrCodeImage = generated

                withAnimation(.spring(response: 0.5, dampingFraction: 0.78)) {
                    showCard = true
                }
                sharePresentTask = Task {
                    try? await Task.sleep(nanoseconds: 150_000_000)
                    guard !Task.isCancelled else { return }
                    isShareSheetPresented = true
                }
            }
        }
    }

    private func codeCard(qrSize: CGFloat) -> some View {
        let centerContentSize: CGFloat = qrSize * (50.0 / Self.maxQRSize)
        let centerBackgroundSize: CGFloat = qrSize * (55.0 / Self.maxQRSize)
        let cardInternalPadding: CGFloat = qrSize * (Self.cardPadding / Self.maxQRSize)

        return VStack(spacing: 0.0) {
            header()
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

                        center()
                            .frame(width: centerContentSize, height: centerContentSize)
                    }
                }
                .padding([.leading, .trailing, .bottom], cardInternalPadding)
                .accessibilityLabel("Share QR code")
                .accessibilityIdentifier("share-qr-code")
            }
        }
        .background(.white)
        .clipShape(RoundedRectangle(cornerRadius: DesignConstants.CornerRadius.large))
        .padding(.horizontal, DesignConstants.Spacing.step10x)
    }

    private func dismissFlow() {
        sharePresentTask?.cancel()
        // Signal the share-sheet presenter to tear down the activity controller;
        // otherwise it stays orphaned on screen after the card animates away.
        isShareSheetPresented = false
        withAnimation(.easeOut(duration: 0.25)) {
            showCard = false
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
            isPresented = false
        }
    }
}
