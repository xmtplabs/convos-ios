import Combine
import ConvosCore
import Observation
import SwiftUI

struct AvatarView: View {
    let imageURL: URL?
    let fallbackName: String
    let cacheableObject: any ImageCacheable
    let placeholderImage: UIImage?
    let placeholderImageName: String?
    @State private var cachedImage: UIImage?
    @State private var isLoading: Bool = false

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
        .task(id: imageURL) {
            await loadImage()
        }
        .cachedImage(for: cacheableObject) { image in
            cachedImage = image
        }
    }

    @MainActor
    private func loadImage() async {
        let unsafeCacheable = cacheableObject
        guard let imageURL else {
            cachedImage = await ImageCache.shared.imageAsync(for: unsafeCacheable)
            return
        }

        if let existingImage = await ImageCache.shared.imageAsync(for: imageURL) {
            cachedImage = existingImage
            ImageCache.shared.setImage(existingImage, for: unsafeCacheable)
            return
        }

        // Show stale object cache as placeholder while fresh URL-based image loads.
        // Better UX than showing blank/monogram during network fetch.
        if let cachedObjectImage = await ImageCache.shared.imageAsync(for: unsafeCacheable) {
            cachedImage = cachedObjectImage
        }

        isLoading = true

        do {
            let (data, _) = try await URLSession.shared.data(from: imageURL)
            if let image = UIImage(data: data) {
                ImageCache.shared.setImage(image, for: imageURL.absoluteString)
                ImageCache.shared.setImage(image, for: unsafeCacheable)
                cachedImage = image
            }
        } catch {
            Log.error("Error loading image cacheable object: \(unsafeCacheable) from url: \(imageURL)")
            cachedImage = nil
        }

        isLoading = false
    }
}

struct ProfileAvatarView: View {
    let profile: Profile
    let profileImage: UIImage?
    let useSystemPlaceholder: Bool

    var body: some View {
        AvatarView(
            imageURL: profile.avatarURL,
            fallbackName: profile.displayName,
            cacheableObject: profile,
            placeholderImage: profileImage,
            placeholderImageName: useSystemPlaceholder ? "person.crop.circle.fill" : nil
        )
    }
}

/// Lightweight avatar optimized for scroll performance in conversation lists.
/// Uses synchronous memory cache lookup first - if hit, no async work happens.
/// Falls back to async loading only if image isn't in memory cache.
/// This prevents layout invalidation during scroll for already-cached images.
struct ConversationAvatarView: View {
    let conversation: Conversation
    let conversationImage: UIImage?

    @State private var asyncLoadedImage: UIImage?

    private var imageURL: URL? {
        switch conversation.avatarType {
        case .customImage:
            return conversation.imageURL
        case .profile(let profile):
            return profile.avatarURL
        default:
            return nil
        }
    }

    private var syncCachedImage: UIImage? {
        // Check URL cache first - this correctly handles URL changes
        // (identifier cache would return stale image if URL changed)
        if let url = imageURL {
            return ImageCache.shared.image(for: url.absoluteString)
        }
        // No URL - fall back to identifier cache for non-image avatar types
        switch conversation.avatarType {
        case .customImage:
            return ImageCache.shared.image(for: conversation)
        case .profile(let profile):
            return ImageCache.shared.image(for: profile)
        default:
            return nil
        }
    }

    var body: some View {
        Group {
            if let conversationImage {
                Image(uiImage: conversationImage)
                    .resizable()
                    .scaledToFill()
            } else if let image = syncCachedImage {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
            } else if let image = asyncLoadedImage {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
            } else {
                fallbackContent
            }
        }
        .aspectRatio(1.0, contentMode: .fit)
        .clipShape(Circle())
        .task(id: imageURL) {
            guard syncCachedImage == nil else { return }
            await loadImage()
        }
        .cachedImage(for: conversation) { image in
            asyncLoadedImage = image
        }
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

    @MainActor
    private func loadImage() async {
        switch conversation.avatarType {
        case .customImage:
            await loadCustomImage()
        case .profile(let profile):
            await loadProfileImage(profile)
        default:
            break
        }
    }

    @MainActor
    private func loadCustomImage() async {
        guard let url = conversation.imageURL else {
            asyncLoadedImage = await ImageCache.shared.imageAsync(for: conversation)
            return
        }

        if let existingImage = await ImageCache.shared.imageAsync(for: url) {
            asyncLoadedImage = existingImage
            ImageCache.shared.setImage(existingImage, for: conversation)
            return
        }

        do {
            let (data, _) = try await URLSession.shared.data(from: url)
            if let image = UIImage(data: data) {
                ImageCache.shared.setImage(image, for: url.absoluteString)
                ImageCache.shared.setImage(image, for: conversation)
                asyncLoadedImage = image
            }
        } catch {
            Log.error("Error loading conversation image from url: \(url)")
        }
    }

    @MainActor
    private func loadProfileImage(_ profile: Profile) async {
        guard let url = profile.avatarURL else {
            asyncLoadedImage = await ImageCache.shared.imageAsync(for: profile)
            return
        }

        if let existingImage = await ImageCache.shared.imageAsync(for: url) {
            asyncLoadedImage = existingImage
            ImageCache.shared.setImage(existingImage, for: profile)
            ImageCache.shared.setImage(existingImage, for: conversation)
            return
        }

        do {
            let (data, _) = try await URLSession.shared.data(from: url)
            if let image = UIImage(data: data) {
                ImageCache.shared.setImage(image, for: url.absoluteString)
                ImageCache.shared.setImage(image, for: profile)
                ImageCache.shared.setImage(image, for: conversation)
                asyncLoadedImage = image
            }
        } catch {
            Log.error("Error loading profile avatar from url: \(url)")
        }
    }
}

/// Lightweight avatar optimized for scroll performance in lists.
/// Uses synchronous memory cache lookup first - if hit, no async work happens.
/// Falls back to async loading only if image isn't in memory cache.
/// This prevents layout invalidation during scroll for already-cached images.
struct MessageAvatarView: View {
    let profile: Profile
    let size: CGFloat

    @State private var asyncLoadedImage: UIImage?

    private var imageURL: URL? {
        profile.avatarURL
    }

    private var syncCachedImage: UIImage? {
        // Check URL cache first - this correctly handles URL changes
        // (identifier cache would return stale image if URL changed)
        if let url = imageURL {
            return ImageCache.shared.image(for: url.absoluteString)
        }
        // No URL - fall back to identifier cache
        return ImageCache.shared.image(for: profile)
    }

    var body: some View {
        Group {
            if let image = syncCachedImage {
                Image(uiImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
            } else if let image = asyncLoadedImage {
                Image(uiImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
            } else {
                MonogramView(name: profile.displayName)
            }
        }
        .frame(width: size, height: size)
        .clipShape(Circle())
        .task(id: imageURL) {
            guard syncCachedImage == nil else { return }
            await loadImage()
        }
        .cachedImage(for: profile) { image in
            asyncLoadedImage = image
        }
    }

    @MainActor
    private func loadImage() async {
        guard let imageURL else {
            asyncLoadedImage = await ImageCache.shared.imageAsync(for: profile)
            return
        }

        if let existingImage = await ImageCache.shared.imageAsync(for: imageURL) {
            asyncLoadedImage = existingImage
            ImageCache.shared.setImage(existingImage, for: profile)
            return
        }

        do {
            let (data, _) = try await URLSession.shared.data(from: imageURL)
            if let image = UIImage(data: data) {
                ImageCache.shared.setImage(image, for: imageURL.absoluteString)
                ImageCache.shared.setImage(image, for: profile)
                asyncLoadedImage = image
            }
        } catch {
            Log.error("Error loading avatar for profile \(profile.displayName) from url: \(imageURL)")
        }
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
