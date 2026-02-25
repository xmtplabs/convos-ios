import SwiftUI
import UIKit

struct AutoShareSheetView<Content: View>: View {
    let itemsToShare: [Any]
    let backgroundContent: Content
    let onDismiss: (() -> Void)?

    @State private var isShareSheetPresented: Bool = false
    @Environment(\.dismiss) private var dismiss: DismissAction

    init(
        items: [Any],
        onDismiss: (() -> Void)? = nil,
        @ViewBuilder backgroundContent: () -> Content
    ) {
        self.itemsToShare = items
        self.onDismiss = onDismiss
        self.backgroundContent = backgroundContent()
    }

    var body: some View {
        ZStack {
            // Background content that remains visible
            backgroundContent
                .frame(maxWidth: .infinity, maxHeight: .infinity)

            // Invisible view to anchor the share sheet
            Color.clear
                .frame(width: 1, height: 1)
                .background(
                    ActivityViewController(
                        activityItems: itemsToShare,
                        isPresented: $isShareSheetPresented,
                        onDismiss: {
                            onDismiss?()
                            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                                dismiss()
                            }
                        }
                    )
                )
        }
        .onAppear {
            // Small delay to ensure view hierarchy is ready
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                isShareSheetPresented = true
            }
        }
    }
}

// UIViewControllerRepresentable wrapper for UIActivityViewController
private struct ActivityViewController: UIViewControllerRepresentable {
    let activityItems: [Any]
    @Binding var isPresented: Bool
    let onDismiss: (() -> Void)?

    func makeUIViewController(context: Context) -> UIViewController {
        UIViewController()
    }

    func updateUIViewController(_ uiViewController: UIViewController, context: Context) {
        if isPresented && uiViewController.presentedViewController == nil {
            let activityVC = UIActivityViewController(
                activityItems: activityItems,
                applicationActivities: nil
            )

            // Configure for iPad
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
                onDismiss?()
            }

            uiViewController.present(activityVC, animated: true)
        }
    }
}

// Alternative simplified initializer for common use cases
extension AutoShareSheetView where Content == AnyView {
    init(
        items: [Any],
        title: String = "Sharing...",
        subtitle: String? = nil,
        icon: Image = Image(systemName: "square.and.arrow.up.circle.fill"),
        onDismiss: (() -> Void)? = nil
    ) {
        self.itemsToShare = items
        self.onDismiss = onDismiss
        self.backgroundContent = AnyView(
            VStack(spacing: 16) {
                icon
                    .font(.system(size: 60))
                    .foregroundColor(.accentColor)

                Text(title)
                    .font(.title2)
                    .fontWeight(.semibold)

                if let subtitle = subtitle {
                    Text(subtitle)
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color(.systemBackground))
        )
    }
}

// swiftlint:disable force_unwrapping

#Preview {
    Group {
        AutoShareSheetView(
            items: ["Sample text to share"],
            onDismiss: nil
        ) {
            ZStack {
                Color.black.opacity(0.5)
                    .background(.ultraThinMaterial)
                    .ignoresSafeArea()

                VStack(spacing: 0.0) {
                    VStack(spacing: 0.0) {
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
                        .offset(y: 5.0) // qr code is generated with some padding
                        .foregroundStyle(.colorTextSecondary)
                        .textCase(.uppercase)
                        .font(.caption)
                        .frame(height: DesignConstants.Spacing.step10x)

                        QRCodeView(url: URL(string: "http://example.com")!)
                            .padding([.leading, .trailing, .bottom], DesignConstants.Spacing.step10x)
                    }
                    .background(.white)
                    .clipShape(RoundedRectangle(cornerRadius: DesignConstants.CornerRadius.large))

                    Spacer()
                }
            }
        }
    }
}

// swiftlint:enable force_unwrapping
