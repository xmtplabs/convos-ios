#if canImport(UIKit)
import ConvosCore
import SwiftUI

/// Avatar keyed by inbox id that renders the canonical avatar from the unified
/// profile system (newest avatar across every conversation) and stays in sync
/// with profile changes via `ProfilesRepository.profilePublisher`. Sharing the
/// `Profile.imageCacheIdentifier == inboxId` key means this shares the
/// encrypted-image cache with the chat surfaces (message bubbles, members
/// list), so an update flowing through the repository invalidates once and
/// every consumer picks up the new image.
///
/// When no repository is injected (previews / uninjected subtrees) the view
/// falls through to the placeholder for the empty profile rather than crashing.
public struct InboxProfileAvatarView: View {
    let inboxId: String
    let fallbackName: String
    let placeholderEmoji: String?
    let agentVerification: AgentVerification
    /// Rendered when the canonical profile has no avatar yet - including a
    /// synthetic contact (suggested agent, agent-share placeholder) that carries
    /// its own avatar but has no profile row. Keeps the shared-cache benefit for
    /// real profiles while preserving the caller's own image instead of dropping
    /// to the placeholder.
    var fallbackCacheable: (any ImageCacheable)?

    public init(inboxId: String, fallbackName: String, placeholderEmoji: String?, agentVerification: AgentVerification, fallbackCacheable: (any ImageCacheable)? = nil) {
        self.inboxId = inboxId
        self.fallbackName = fallbackName
        self.placeholderEmoji = placeholderEmoji
        self.agentVerification = agentVerification
        self.fallbackCacheable = fallbackCacheable
    }

    @Environment(\.profilesRepository) private var repository: ProfilesRepository?
    @State private var renderedProfile: Profile?

    public var body: some View {
        AvatarView(
            fallbackName: fallbackName,
            cacheableObject: resolvedCacheable,
            placeholderImage: nil,
            placeholderEmoji: placeholderEmoji,
            placeholderImageName: nil,
            agentVerification: agentVerification
        )
        .task(id: inboxId) {
            await observeProfile(for: inboxId)
        }
    }

    /// Prefer the canonical profile's avatar (shared image cache with chat
    /// surfaces). When it has no image, fall back to the caller's own cacheable
    /// so a synthetic contact still renders its provided avatar.
    private var resolvedCacheable: any ImageCacheable {
        if let renderedProfile, renderedProfile.imageCacheURL != nil {
            return renderedProfile
        }
        if let fallbackCacheable, fallbackCacheable.imageCacheURL != nil {
            return fallbackCacheable
        }
        return renderedProfile ?? Profile.empty(inboxId: inboxId)
    }

    /// Subscribes to the unified profile for `subscribedInboxId` and maps each
    /// emission into a `Profile` for the shared avatar cache. Awaiting the
    /// publisher's async `values` sequence keeps the subscription tied to the
    /// view's lifetime (cancelled when the task is torn down or `inboxId`
    /// changes) without the resubscription churn a recomputed `onReceive`
    /// publisher would cause. No repository (previews) leaves the placeholder.
    private func observeProfile(for subscribedInboxId: String) async {
        guard let repository else { return }
        let stream = repository.profilePublisher(inboxId: subscribedInboxId).values
        for await unified in stream {
            let avatar: Avatar? = unified.displayAvatar(for: nil)
            let profile = Profile(
                inboxId: unified.inboxId,
                conversationId: "",
                name: unified.name,
                avatar: avatar?.url,
                avatarSalt: avatar?.salt,
                avatarNonce: avatar?.nonce,
                avatarKey: avatar?.key,
                isAgent: unified.isAgent,
                metadata: unified.metadata
            )
            renderedProfile = profile
        }
    }
}
#endif
