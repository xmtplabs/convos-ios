import ConvosCore
import ConvosLogging
import SwiftUI
import UIKit

struct HTMLAttachmentBubble: View {
    let attachment: HydratedAttachment
    let profile: Profile
    let reactions: [MessageReaction]
    var onTapAvatar: (() -> Void)?
    var onTapReactions: (() -> Void)?
    var cornerRadiusOverride: CGFloat?

    @Environment(\.horizontalSizeClass) private var horizontalSizeClass: UserInterfaceSizeClass?
    @State private var renderedImage: UIImage?
    @State private var hasLoadFailed: Bool = false
    @State private var bottomEdgeColor: Color?

    var body: some View {
        VStack(spacing: 0) {
            header
            preview
        }
        .frame(maxWidth: .infinity)
        .frame(height: Constant.cellHeight)
        .background(Color.colorBackgroundSurfaceless)
        .overlay(alignment: .bottom) {
            bottomFade
        }
        .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
        .overlay(alignment: .bottomLeading) {
            if !reactions.isEmpty {
                let tap: () -> Void = {
                    onTapReactions?()
                }
                MediaContainerReax(reactions: reactions, onTap: tap)
            }
        }
        .accessibilityIdentifier("html-attachment-bubble")
        .accessibilityLabel("HTML page from \(profile.displayName)")
        .task(id: attachment.key) {
            await loadThumbnail()
        }
    }

    @ViewBuilder
    private var header: some View {
        HStack(spacing: DesignConstants.Spacing.step2x) {
            senderTapTarget
            Spacer()
            viewAffordance
        }
        .padding(.horizontal, DesignConstants.Spacing.step4x)
        .frame(height: Constant.headerHeight)
        .frame(maxWidth: .infinity)
        .overlay(alignment: .bottom) {
            Color.colorBorderSubtle
                .frame(height: Constant.borderHeight)
                .padding(.horizontal, DesignConstants.Spacing.step4x)
        }
    }

    @ViewBuilder
    private var senderTapTarget: some View {
        let tap: () -> Void = {
            onTapAvatar?()
        }
        Button(action: tap) {
            HStack(spacing: DesignConstants.Spacing.step2x) {
                ProfileAvatarView(
                    profile: profile,
                    profileImage: nil,
                    useSystemPlaceholder: false
                )
                .frame(width: DesignConstants.ImageSizes.smallAvatar, height: DesignConstants.ImageSizes.smallAvatar)
                Text(profile.displayName)
                    .font(.footnote)
                    .foregroundStyle(.colorTextPrimary)
                    .lineLimit(1)
                    .accessibilityIdentifier("html-attachment-bubble-sender")
            }
        }
        .buttonStyle(.plain)
        .background(GesturePassthroughBackground())
        .accessibilityLabel("View \(profile.displayName)'s profile")
    }

    @ViewBuilder
    private var viewAffordance: some View {
        HStack(spacing: 4) {
            Text("View")
                .font(.footnote)
            Image(systemName: "chevron.right")
                .font(.footnote)
        }
        .foregroundStyle(.secondary)
        .accessibilityHidden(true)
    }

    @ViewBuilder
    private var preview: some View {
        GeometryReader { proxy in
            if let renderedImage {
                Image(uiImage: renderedImage)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .frame(width: proxy.size.width, height: proxy.size.height, alignment: .top)
                    .clipped()
            } else {
                ZStack {
                    Rectangle().fill(Color.colorFillMinimal)
                    if hasLoadFailed {
                        Image(systemName: "exclamationmark.triangle")
                            .font(.title2)
                            .foregroundStyle(.secondary)
                    } else {
                        ProgressView()
                    }
                }
                .frame(width: proxy.size.width, height: proxy.size.height)
            }
        }
    }

    @ViewBuilder
    private var bottomFade: some View {
        let endColor: Color = bottomEdgeColor ?? .clear
        LinearGradient(
            colors: [endColor.opacity(0), endColor],
            startPoint: .top,
            endPoint: .bottom
        )
        .frame(height: Constant.fadeHeight)
        .allowsHitTesting(false)
    }

    private var cornerRadius: CGFloat {
        if let cornerRadiusOverride { return cornerRadiusOverride }
        return horizontalSizeClass == .regular ? DesignConstants.CornerRadius.medium : 0
    }

    private func loadThumbnail() async {
        renderedImage = nil
        bottomEdgeColor = nil
        hasLoadFailed = false
        if let cached = HTMLThumbnailRenderer.shared.cachedThumbnail(for: attachment.key) {
            renderedImage = cached
            bottomEdgeColor = cached.convos_bottomCenterColor()
            return
        }
        do {
            let fileURL = try await FileAttachmentLoader.loadFile(for: attachment)
            let image = await HTMLThumbnailRenderer.shared.thumbnail(
                for: attachment.key,
                fileURL: fileURL
            )
            renderedImage = image
            bottomEdgeColor = image?.convos_bottomCenterColor()
            hasLoadFailed = image == nil
        } catch {
            Log.error("Failed to load HTML attachment thumbnail: \(error)")
            hasLoadFailed = true
        }
    }

    private enum Constant {
        static let headerHeight: CGFloat = 56.0
        static let cellHeight: CGFloat = 500.0
        static let fadeHeight: CGFloat = 68.0
        static let borderHeight: CGFloat = 1.0
    }
}

private extension UIImage {
    /// Returns the color of a single pixel sampled near the bottom-center of the image.
    /// Used to derive a fade-out gradient end color that matches the rendered HTML body bg.
    func convos_bottomCenterColor() -> Color? {
        guard let cgImage,
              cgImage.width > 0,
              cgImage.height > 0 else { return nil }
        let x = cgImage.width / 2
        let y = max(cgImage.height - 4, 0)
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        var pixel: [UInt8] = [0, 0, 0, 0]
        let bitmapInfo = CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue
        guard let context = CGContext(
            data: &pixel,
            width: 1,
            height: 1,
            bitsPerComponent: 8,
            bytesPerRow: 4,
            space: colorSpace,
            bitmapInfo: bitmapInfo
        ) else { return nil }
        context.draw(cgImage, in: CGRect(x: -x, y: -y, width: cgImage.width, height: cgImage.height))
        let red = CGFloat(pixel[0]) / 255.0
        let green = CGFloat(pixel[1]) / 255.0
        let blue = CGFloat(pixel[2]) / 255.0
        let alpha = CGFloat(pixel[3]) / 255.0
        if alpha < 0.05 { return nil }
        return Color(.sRGB, red: red, green: green, blue: blue, opacity: alpha)
    }
}
