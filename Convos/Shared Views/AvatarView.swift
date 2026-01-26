import ConvosCore
import SwiftUI

struct AvatarView: View {
    let fallbackName: String
    let cacheableObject: any ImageCacheable
    let placeholderImage: UIImage?
    let placeholderImageName: String?
    @State private var cachedImage: UIImage?

    var body: some View {
        Group {
            if let image = placeholderImage ?? cachedImage {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFit()
                    .aspectRatio(contentMode: .fill)
            } else if let placeholderImageName {
                Image(systemName: placeholderImageName)
                    .resizable()
                    .scaledToFit()
                    .aspectRatio(contentMode: .fill)
                    .symbolEffect(.bounce.up.byLayer, options: .nonRepeating)
                    .padding(DesignConstants.Spacing.step2x)
                    .foregroundStyle(.colorTextPrimaryInverted)
                    .background(.colorFillTertiary)
            } else {
                MonogramView(name: fallbackName)
            }
        }
        .aspectRatio(1.0, contentMode: .fit)
        .clipShape(Circle())
        .cachedImage(for: cacheableObject, into: $cachedImage)
    }
}

struct ProfileAvatarView: View {
    let profile: Profile
    let profileImage: UIImage?
    let useSystemPlaceholder: Bool

    var body: some View {
        AvatarView(
            fallbackName: profile.displayName,
            cacheableObject: profile,
            placeholderImage: profileImage,
            placeholderImageName: useSystemPlaceholder ? "person.crop.circle.fill" : nil
        )
    }
}

/// Lightweight avatar optimized for scroll performance in conversation lists.
/// Uses the new cachedImage modifier for automatic loading and URL change detection.
struct ConversationAvatarView: View {
    let conversation: Conversation
    let conversationImage: UIImage?

    @State private var cachedImage: UIImage?

    var body: some View {
        Group {
            if let conversationImage {
                Image(uiImage: conversationImage)
                    .resizable()
                    .scaledToFill()
            } else if let image = cachedImage {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
            } else {
                fallbackContent
            }
        }
        .aspectRatio(1.0, contentMode: .fit)
        .clipShape(Circle())
        .cachedImage(for: conversation, into: $cachedImage)
    }

    @ViewBuilder
    private var fallbackContent: some View {
        switch conversation.avatarType {
        case .customImage:
            MonogramView(name: conversation.computedDisplayName)
        case .profile(let profile):
            MonogramView(name: profile.displayName)
        case .clustered(let profiles):
            ClusteredAvatarView(profiles: profiles)
        case .emoji(let emoji):
            EmojiAvatarView(emoji: emoji)
        case .monogram(let name):
            MonogramView(name: name)
        }
    }
}

/// Lightweight avatar optimized for scroll performance in lists.
/// Uses the new cachedImage modifier for automatic loading and URL change detection.
struct MessageAvatarView: View {
    let profile: Profile
    let size: CGFloat

    @State private var cachedImage: UIImage?

    var body: some View {
        Group {
            if let image = cachedImage {
                Image(uiImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
            } else {
                MonogramView(name: profile.displayName)
            }
        }
        .frame(width: size, height: size)
        .clipShape(Circle())
        .cachedImage(for: profile, into: $cachedImage)
    }
}

#Preview {
    @Previewable @State var profileImage: UIImage?
    let profile: Profile = .mock(name: "John Doe")
    ProfileAvatarView(profile: profile, profileImage: profileImage, useSystemPlaceholder: true)
}

#Preview {
    @Previewable @State var conversationImage: UIImage?
    let conversation = Conversation.mock(members: [.mock(), .mock()])
    ConversationAvatarView(conversation: conversation, conversationImage: nil)
}
