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
        // First check object cache for instant updates
        if let cachedObjectImage = await ImageCache.shared.imageAsync(for: cacheableObject) {
            cachedImage = cachedObjectImage
            // fall through so we attempt to fetch the latest
        }

        guard let imageURL else {
            cachedImage = nil
            return
        }

        // Check URL-based cache (only if object cache was empty)
        if let existingImage = await ImageCache.shared.imageAsync(for: imageURL) {
            cachedImage = existingImage
            return // Early return to avoid network request if URL cache has the image
        }

        isLoading = true

        do {
            let (data, _) = try await URLSession.shared.data(from: imageURL)
            if let image = UIImage(data: data) {
                // Cache the image for future use
                ImageCache.shared.setImage(image, for: imageURL.absoluteString)

                // Also cache by object if available for instant cross-view updates
                ImageCache.shared.setImage(image, for: cacheableObject)

                cachedImage = image
            }
        } catch {
            // Keep showing monogram on error
            Log.error("Error loading image cacheable object: \(cacheableObject) from url: \(imageURL)")
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

struct ConversationAvatarView: View {
    let conversation: Conversation
    let conversationImage: UIImage?

    var body: some View {
        if conversation.imageURL != nil || conversationImage != nil {
            // Fall back to URL-based loading with conversation object for cache awareness
            AvatarView(
                imageURL: conversation.imageURL,
                fallbackName: "",
                cacheableObject: conversation,
                placeholderImage: conversationImage,
                placeholderImageName: nil
            )
        } else {
            MonogramView(text: "")
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
