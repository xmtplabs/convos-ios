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
    /// Flat top padding above the card, measured from the top of the region
    /// the card occupies (the container safe area, or the device safe-area
    /// top when `ignoresToolbarSafeArea` is set).
    let topPadding: CGFloat
    /// When set, the card extends up into the toolbar band of the top safe
    /// area while still respecting the window's device safe area (status bar
    /// and Dynamic Island). Lets a caller pull a tall card up out of the
    /// toolbar band so it clears the share sheet below it without sliding
    /// under the status bar.
    var ignoresToolbarSafeArea: Bool = false
    /// Optional hook fired from the native share sheet's completion handler
    /// so callers can record a metric (e.g. `sharedConversation`) keyed off
    /// the selected `UIActivity.ActivityType` and success flag.
    var onShareCompleted: ((UIActivity.ActivityType?, Bool, Error?) -> Void)?
    @ViewBuilder let header: () -> Header
    @ViewBuilder let center: () -> Center

    @State private var showCard: Bool = false
    @State private var isShareSheetPresented: Bool = false
    @State private var qrCodeImage: UIImage?
    /// Defers presenting the share sheet until the card has animated in.
    /// Tracked so dismissing during the gap cancels the pending present.
    @State private var sharePresentTask: Task<Void, Never>?
    @Environment(\.displayScale) private var displayScale: CGFloat
    /// Window-level safe area (device bezel only, no toolbar contribution),
    /// used to keep the card below the status bar while it ignores the
    /// toolbar's safe-area band.
    @Environment(\.safeAreaInsets) private var windowSafeAreaInsets: EdgeInsets

    private static var headerHeight: CGFloat { 40.0 }
    private static var cardPadding: CGFloat { 40.0 }
    private static var maxQRSize: CGFloat { 220.0 }
    private static var shareSheetFraction: CGFloat { 0.55 }

    /// Sizes the QR so the card fits between its top position and the share
    /// sheet, which covers the bottom `shareSheetFraction` of the screen.
    /// Measured in window coordinates: the overlay's container is shorter
    /// than the screen when the contact card is presented inside a sheet, so
    /// container-local math would over-estimate the available height and the
    /// card would render larger there than on a navigation stack.
    private func qrDisplaySize(in geometry: GeometryProxy, cardTopPadding: CGFloat) -> CGFloat {
        let globalFrame: CGRect = geometry.frame(in: .global)
        let shareSheetTop: CGFloat = globalFrame.maxY * (1.0 - Self.shareSheetFraction)
        let cardTop: CGFloat = globalFrame.minY + cardTopPadding
        let availableHeight = shareSheetTop
            - cardTop
            - Self.headerHeight
            - Self.cardPadding
            - DesignConstants.Spacing.step10x
        let availableWidth = geometry.size.width
            - DesignConstants.Spacing.step10x * 2
            - Self.cardPadding * 2
        let maxFit = min(availableHeight, availableWidth)
        return min(max(maxFit, 120.0), Self.maxQRSize)
    }

    /// The edges the overlay's container extends past; hoisted so the
    /// modifier argument in `body` stays ternary-free.
    private var ignoredEdges: Edge.Set {
        ignoresToolbarSafeArea ? .top : []
    }

    /// The card's top padding resolved against the (possibly expanded)
    /// container. When the card ignores the toolbar safe area, the
    /// container's top edge can sit above the device safe area (navigation
    /// stack) or already below it (sheet); clamp so the card never rises
    /// above the window's safe area.
    private func resolvedTopPadding(in geometry: GeometryProxy) -> CGFloat {
        guard ignoresToolbarSafeArea else { return topPadding }
        let containerTop: CGFloat = geometry.frame(in: .global).minY
        let deviceInset: CGFloat = max(windowSafeAreaInsets.top - containerTop, 0.0)
        return deviceInset + topPadding
    }

    var body: some View {
        GeometryReader { geometry in
            let cardTopPadding: CGFloat = resolvedTopPadding(in: geometry)
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
                        codeCard(qrSize: qrDisplaySize(in: geometry, cardTopPadding: cardTopPadding))
                        Spacer()
                    }
                    .padding(.top, cardTopPadding)
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
                        },
                        onCompletion: onShareCompleted
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
        .ignoresSafeArea(.container, edges: ignoredEdges)
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
