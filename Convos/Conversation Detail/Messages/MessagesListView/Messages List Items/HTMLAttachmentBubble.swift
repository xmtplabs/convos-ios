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

    var body: some View {
        VStack(spacing: 0) {
            header
            preview
        }
        .frame(maxWidth: .infinity)
        .frame(height: Constant.cellHeight)
        .background(Color.colorBackgroundSurfaceless)
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
        if let renderedImage {
            Image(uiImage: renderedImage)
                .resizable()
                .scaledToFill()
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
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
        }
    }

    private var cornerRadius: CGFloat {
        if let cornerRadiusOverride { return cornerRadiusOverride }
        return horizontalSizeClass == .regular ? DesignConstants.CornerRadius.medium : 0
    }

    private func loadThumbnail() async {
        if let cached = HTMLThumbnailRenderer.shared.cachedThumbnail(for: attachment.key) {
            renderedImage = cached
            return
        }
        do {
            let fileURL = try await FileAttachmentLoader.loadFile(for: attachment)
            let image = await HTMLThumbnailRenderer.shared.thumbnail(
                for: attachment.key,
                fileURL: fileURL
            )
            renderedImage = image
            hasLoadFailed = image == nil
        } catch {
            Log.error("Failed to load HTML attachment thumbnail: \(error)")
            hasLoadFailed = true
        }
    }

    private enum Constant {
        static let headerHeight: CGFloat = 56.0
        static let cellHeight: CGFloat = 500.0
        static let borderHeight: CGFloat = 1.0
    }
}
