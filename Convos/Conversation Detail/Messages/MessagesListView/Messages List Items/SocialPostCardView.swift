import ConvosCore
import SwiftUI

struct SocialPostCardView: View {
    let platform: SocialPlatform
    let username: String?
    let authorName: String?
    let bodyText: String
    let image: UIImage?
    let imageAspectRatio: CGFloat?
    var authorAvatarURL: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 0.0) {
            bodySection
            if let image {
                imageSection(image)
            }
            authorFooter
        }
        .frame(width: 280.0, alignment: .leading)
    }

    @ViewBuilder
    private var avatarImage: some View {
        if let urlString = authorAvatarURL, let url = URL(string: urlString) {
            AsyncImage(url: url) { image in
                image
                    .resizable()
                    .aspectRatio(contentMode: .fill)
            } placeholder: {
                Image(systemName: "person.crop.circle.fill")
                    .resizable()
                    .foregroundStyle(.colorTextSecondary)
            }
        } else {
            Image(systemName: "person.crop.circle.fill")
                .resizable()
                .foregroundStyle(.colorTextSecondary)
        }
    }

    private func imageSection(_ image: UIImage) -> some View {
        let ratio = imageAspectRatio ?? 1.0
        let clamped = min(max(ratio, 0.75), 2.0)
        return Image(uiImage: image)
            .resizable()
            .aspectRatio(contentMode: .fill)
            .frame(width: 280.0, height: 280.0 / clamped)
            .clipped()
            .overlay(
                Rectangle()
                    .strokeBorder(.colorBorderEdge, lineWidth: 1.0)
            )
    }

    private var bodySection: some View {
        Text(bodyText)
            .font(.callout)
            .multilineTextAlignment(.leading)
            .foregroundStyle(.colorTextPrimary)
            .lineLimit(8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, DesignConstants.Spacing.step4x)
            .padding(.vertical, DesignConstants.Spacing.step3x)
            .background(.colorFillMinimal)
    }

    private var authorFooter: some View {
        HStack(alignment: .top, spacing: 0.0) {
            VStack(alignment: .leading, spacing: DesignConstants.Spacing.stepHalf) {
                if let authorName {
                    Text(authorName)
                        .font(.callout.weight(.medium))
                        .foregroundStyle(.colorTextPrimary)
                        .lineLimit(1)
                }
                HStack(spacing: DesignConstants.Spacing.stepX) {
                    avatarImage
                        .frame(width: 16.0, height: 16.0)
                        .clipShape(Circle())
                    if let username {
                        Text("@\(username)")
                            .font(.caption)
                            .foregroundStyle(.colorTextSecondary)
                            .lineLimit(1)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            Image(platform.logoAssetName)
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(width: 24.0, height: 24.0)
                .frame(width: 40.0, height: 40.0)
                .foregroundStyle(platform == .bluesky ? Color(red: 0.0, green: 0.416, blue: 1.0) : .colorFillPrimary)
        }
        .padding(.leading, DesignConstants.Spacing.step4x)
        .padding(.trailing, DesignConstants.Spacing.step3x)
        .padding(.vertical, DesignConstants.Spacing.step3x)
        .background(.colorFillSubtle)
    }
}

#Preview("Social Post - Twitter with Image") {
    SocialPostCardView(
        platform: .twitter,
        username: "elonmusk",
        authorName: "Elon Musk",
        bodyText: "The content of the social media post is so funny, I want to post it here, you gotta read it man, it's so funny",
        image: UIImage(systemName: "photo"),
        imageAspectRatio: 1.0
    )
    .padding()
}

#Preview("Social Post - Threads") {
    SocialPostCardView(
        platform: .threads,
        username: "mikeindustries",
        authorName: "Mike Davidson",
        bodyText: "The content of the social media post is so funny, I want to post it here, you gotta read it man, it's so funny",
        image: UIImage(systemName: "photo"),
        imageAspectRatio: 1.0
    )
    .padding()
}

#Preview("Social Post - Bluesky no image") {
    SocialPostCardView(
        platform: .bluesky,
        username: "bsky.app",
        authorName: "Bluesky",
        bodyText: "A short post without an image attached.",
        image: nil,
        imageAspectRatio: nil
    )
    .padding()
}

#Preview("Social Post - Long text") {
    SocialPostCardView(
        platform: .twitter,
        username: "longposter",
        authorName: nil,
        // swiftlint:disable:next line_length
        bodyText: "This is a really long post that should truncate after several lines. Lorem ipsum dolor sit amet, consectetur adipiscing elit. Sed do eiusmod tempor incididunt ut labore et dolore magna aliqua. Ut enim ad minim veniam, quis nostrud exercitation ullamco.",
        image: nil,
        imageAspectRatio: nil
    )
    .padding()
}
