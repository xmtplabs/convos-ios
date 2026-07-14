import ConvosCore
import SwiftUI

struct AvatarView: View {
    let fallbackName: String
    let cacheableObject: any ImageCacheable
    let placeholderImage: UIImage?
    let placeholderEmoji: String?
    let placeholderImageName: String?
    let agentVerification: AgentVerification
    /// Forwarded to the emoji/monogram fallbacks so they render without a
    /// `GeometryReader` when the caller already knows the avatar size (see
    /// `EmojiAvatarView.size`). Nil keeps the self-sizing path.
    let explicitSize: CGFloat?
    @State private var cachedImage: UIImage?

    init(
        fallbackName: String,
        cacheableObject: any ImageCacheable,
        placeholderImage: UIImage?,
        placeholderEmoji: String? = nil,
        placeholderImageName: String?,
        agentVerification: AgentVerification = .unverified,
        explicitSize: CGFloat? = nil
    ) {
        self.fallbackName = fallbackName
        self.cacheableObject = cacheableObject
        self.placeholderImage = placeholderImage
        self.placeholderEmoji = placeholderEmoji
        self.placeholderImageName = placeholderImageName
        self.agentVerification = agentVerification
        self.explicitSize = explicitSize
        _cachedImage = State(initialValue: ImageCache.shared.image(for: cacheableObject))
    }

    var body: some View {
        Group {
            if let image = placeholderImage ?? cachedImage {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFit()
                    .aspectRatio(contentMode: .fill)
            } else if let placeholderEmoji, !placeholderEmoji.isEmpty {
                EmojiAvatarView(emoji: placeholderEmoji, agentVerification: agentVerification, size: explicitSize)
            } else if let placeholderImageName {
                Image(systemName: placeholderImageName)
                    .resizable()
                    .scaledToFit()
                    .aspectRatio(contentMode: .fill)
                    .symbolEffect(.bounce.up.byLayer, options: .nonRepeating)
                    .padding(DesignConstants.Spacing.step2x)
                    .foregroundStyle(.colorTextPrimaryInverted)
                    .background(agentVerification.avatarBackgroundColor)
            } else {
                MonogramView(name: fallbackName, agentVerification: agentVerification, size: explicitSize)
            }
        }
        .aspectRatio(1.0, contentMode: .fit)
        .clipShape(Circle())
        .cachedImage(for: cacheableObject, into: $cachedImage)
        .accessibilityHidden(true)
    }
}

struct ProfileAvatarView: View {
    let profile: Profile
    let profileImage: UIImage?
    let useSystemPlaceholder: Bool
    var agentVerification: AgentVerification = .unverified
    /// Forwarded to `AvatarView` so the emoji/monogram fallbacks skip their
    /// `GeometryReader` when the size is already known (clustered avatars).
    var size: CGFloat?

    var body: some View {
        AvatarView(
            fallbackName: profile.displayName,
            cacheableObject: profile,
            placeholderImage: profileImage,
            placeholderEmoji: profile.profileEmoji,
            placeholderImageName: useSystemPlaceholder ? "person.crop.circle.fill" : nil,
            agentVerification: profile.isAgent ? agentVerification : .unverified,
            explicitSize: size
        )
    }
}

/// Lightweight avatar optimized for scroll performance in conversation lists.
/// Uses the new cachedImage modifier for automatic loading and URL change detection.
struct ConversationAvatarView: View {
    let conversation: Conversation
    let conversationImage: UIImage?
    /// Forwarded to the emoji/monogram/clustered fallbacks so they render
    /// without a `GeometryReader` when the caller knows the avatar size (the
    /// pinned cell passes its fixed avatar size). Nil keeps the self-sizing
    /// path for list rows that only constrain with an outer `.frame`.
    var size: CGFloat?

    @Environment(\.forcedAgentVerification) private var forcedVerification: AgentVerification?
    @Environment(\.pendingAgentIdentity) private var pendingAgentIdentity: PendingAgentAvatarIdentity?
    @State private var cachedImage: UIImage?
    @Environment(\.memberNameOverride) private var memberNameOverride: @Sendable (String) -> String?

    private var hasForcedAgentStyle: Bool {
        forcedVerification?.isVerified == true
    }

    var body: some View {
        Group {
            if let pendingAgentIdentity, pendingAgentIdentity.hasContent {
                // An agent-template flow painted an upcoming identity before
                // the real verified agent joined (see
                // `ConversationViewModel.pendingAgentPresentation`). Render its
                // emoji/photo with verified styling so the indicator advertises
                // the agent the conversation is about to have.
                pendingAgentIdentityAvatar(pendingAgentIdentity)
            } else if hasForcedAgentStyle {
                // The forced-agent style is set by the Agent Builder's
                // conversation indicator before the user taps Make
                // (see `MainTabView.centeredConversationIndicator`). The
                // draft conversation has no real agent yet, so we show
                // the "add agent" icon instead of an "A" monogram.
                PendingAgentAvatarView()
            } else if let conversationImage {
                Image(uiImage: conversationImage)
                    .resizable()
                    .scaledToFill()
            } else if case let .profile(profile, verification) = conversation.avatarType {
                // DM / single-member conversation: observe the member's canonical
                // profile by inboxId so the list avatar updates reactively when
                // their photo changes anywhere, instead of loading the stale
                // snapshot URL captured on the conversation. Shares the per-inbox
                // image cache with the chat surfaces.
                InboxProfileAvatarView(
                    inboxId: profile.inboxId,
                    fallbackName: profile.displayName,
                    placeholderEmoji: dmPlaceholderEmoji(profile: profile, verification: verification),
                    agentVerification: verification,
                    fallbackCacheable: conversation
                )
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

    /// Placeholder for a DM member with no avatar, mirroring the `.profile`
    /// branch of `fallbackContent`: their own emoji, else the conversation's
    /// default emoji for an unverified member, else nil so a verified agent
    /// falls to a monogram.
    private func dmPlaceholderEmoji(profile: Profile, verification: AgentVerification) -> String? {
        if let emoji = profile.profileEmoji, !emoji.isEmpty {
            return emoji
        }
        if verification == .unverified {
            return conversation.defaultEmoji
        }
        return nil
    }

    @ViewBuilder
    private func pendingAgentIdentityAvatar(_ identity: PendingAgentAvatarIdentity) -> some View {
        if let emoji = identity.emoji, !emoji.isEmpty {
            EmojiAvatarView(emoji: emoji, agentVerification: .verified(.convos))
        } else if let urlString = identity.avatarURL, let url = URL(string: urlString) {
            AsyncImage(url: url) { phase in
                if case .success(let image) = phase {
                    image
                        .resizable()
                        .scaledToFill()
                } else {
                    PendingAgentAvatarView()
                }
            }
        } else {
            PendingAgentAvatarView()
        }
    }

    @ViewBuilder
    private var fallbackContent: some View {
        switch conversation.avatarType {
        case .customImage:
            MonogramView(name: conversation.computedDisplayName(memberNameOverride: memberNameOverride), size: size)
        case let .profile(profile, verification):
            if let emoji = profile.profileEmoji, !emoji.isEmpty {
                EmojiAvatarView(emoji: emoji, agentVerification: verification, size: size)
            } else if verification == .unverified {
                EmojiAvatarView(emoji: conversation.defaultEmoji, size: size)
            } else {
                MonogramView(name: profile.displayName, agentVerification: verification, size: size)
            }
        case .clustered(let profiles):
            ClusteredAvatarView(profiles: profiles, size: size)
        case .emoji(let emoji):
            EmojiAvatarView(emoji: emoji, size: size)
        case .monogram(let name):
            MonogramView(name: name, size: size)
        case .pendingAgent:
            PendingAgentAvatarView()
        }
    }
}

/// Avatar used by the Agent Builder's conversation indicator before the
/// user taps Make. A black circle with the "add agent" glyph — mirrors
/// the agent avatar in the inline `AgentBuilderBar`, so the indicator
/// and the bar share visual language while the conversation is still
/// a draft.
struct PendingAgentAvatarView: View {
    var body: some View {
        GeometryReader { geometry in
            let side = min(geometry.size.width, geometry.size.height)
            // Size the glyph proportionally rather than with a fixed inset so
            // it reads like an emoji avatar (centered, with breathing room) at
            // any avatar size -- a touch larger than `EmojiAvatarView`'s 0.43
            // emoji since the glyph carries no internal whitespace.
            let glyphSide = side * 0.5
            ZStack {
                Circle()
                    .fill(Color.black)
                Image("addAgentIcon")
                    .renderingMode(.template)
                    .resizable()
                    .scaledToFit()
                    .foregroundStyle(.white)
                    .frame(width: glyphSide, height: glyphSide)
            }
            .frame(width: side, height: side)
        }
        .aspectRatio(1.0, contentMode: .fit)
    }
}

/// Lightweight avatar optimized for scroll performance in lists.
/// Uses the new cachedImage modifier for automatic loading and URL change detection.
struct MessageAvatarView: View {
    let profile: Profile
    let size: CGFloat
    var agentVerification: AgentVerification = .unverified

    @State private var cachedImage: UIImage?

    var body: some View {
        Group {
            if let image = cachedImage {
                Image(uiImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
            } else if let emoji = profile.profileEmoji, !emoji.isEmpty {
                EmojiAvatarView(emoji: emoji, agentVerification: profile.isAgent ? agentVerification : .unverified)
            } else {
                MonogramView(name: profile.displayName, agentVerification: profile.isAgent ? agentVerification : .unverified)
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
