import ConvosCore
import SwiftUI

struct MessageInviteContainerView: View {
    let invite: MessageInvite
    let style: MessageBubbleType
    let isOutgoing: Bool
    let profile: Profile
    let onTapInvite: ((MessageInvite) -> Void)
    let onTapAvatar: (() -> Void)?

    @Environment(\.messagePressed) private var isPressed: Bool

    var body: some View {
        MessageContainer(style: style, isOutgoing: isOutgoing) {
            MessageInviteView(invite: invite)
                .opacity(isPressed ? 0.7 : 1.0)
                .animation(.easeOut(duration: 0.15), value: isPressed)
        }
    }

    private enum Constant {
        static let bubbleCornerRadius: CGFloat = 20.0
    }
}

#Preview {
    ScrollView {
        VStack {
            MessageInviteContainerView(
                invite: .mock,
                style: .normal,
                isOutgoing: false,
                profile: .mock(),
                onTapInvite: { _ in
                },
                onTapAvatar: {
                })
            MessageInviteContainerView(
                invite: .mock,
                style: .tailed,
                isOutgoing: true,
                profile: .mock(),
                onTapInvite: { _ in
                },
                onTapAvatar: {})
            MessageInviteContainerView(
                invite: .empty,
                style: .normal,
                isOutgoing: false,
                profile: .mock(),
                onTapInvite: { _ in
                },
                onTapAvatar: {
                })
            MessageInviteContainerView(
                invite: .empty,
                style: .tailed,
                isOutgoing: true,
                profile: .mock(),
                onTapInvite: { _ in
                },
                onTapAvatar: {})
            MessageInviteContainerView(
                invite: .mockExploded,
                style: .normal,
                isOutgoing: false,
                profile: .mock(),
                onTapInvite: { _ in
                },
                onTapAvatar: {})
            MessageInviteContainerView(
                invite: .mockExploded,
                style: .tailed,
                isOutgoing: true,
                profile: .mock(),
                onTapInvite: { _ in
                },
                onTapAvatar: {})
            MessageInviteContainerView(
                invite: .mockInviteExpired,
                style: .normal,
                isOutgoing: false,
                profile: .mock(),
                onTapInvite: { _ in
                },
                onTapAvatar: {})
        }
        .padding(.horizontal, DesignConstants.Spacing.step2x)
    }
}

struct MessageInviteView: View {
    let invite: MessageInvite
    @State private var cachedImage: UIImage?

    var title: String {
        if let name = invite.conversationName, !name.isEmpty {
            return name
        }
        return "New Convo"
    }

    private var isExpired: Bool {
        invite.isConversationExpired || invite.isInviteExpired
    }

    var description: String {
        if invite.isConversationExpired { return "Exploded" }
        if invite.isInviteExpired { return "Expired" }
        return "Tap to join"
    }

    private var accessibilityDescriptionIdentifier: String {
        if invite.isConversationExpired { return "invite-preview-exploded-label" }
        if invite.isInviteExpired { return "invite-preview-expired-label" }
        return "invite-preview-subtitle"
    }

    @ViewBuilder
    private var avatarOverlay: some View {
        if isExpired {
            Image(systemName: "burst")
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(height: 76.0)
                .foregroundStyle(.colorTextSecondary)
        } else if let image = cachedImage {
            Image(uiImage: image)
                .resizable()
                .aspectRatio(contentMode: .fill)
        } else if let emoji = invite.emoji, !emoji.isEmpty {
            Text(emoji)
                .font(.system(size: 160))
        } else {
            Image("convosOrangeIcon")
                .resizable()
                .tint(.colorTextPrimaryInverted)
                .foregroundStyle(.colorTextPrimaryInverted)
                .aspectRatio(contentMode: .fit)
                .frame(height: 76.0)
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0.0) {
            Color.colorFillMinimal
                .aspectRatio(1, contentMode: .fit)
                .overlay { avatarOverlay }
                .clipped()
                .opacity(isExpired ? 0.6 : 1.0)
                .accessibilityLabel(invite.imageURL != nil ? "Invite image preview" : (invite.emoji.map { "Invite emoji \($0)" } ?? "Invite placeholder"))
                .accessibilityIdentifier("invite-preview-avatar")

            HStack {
                VStack(alignment: .leading, spacing: 2.0) {
                    Text(title)
                        .lineLimit(2)
                        .accessibilityIdentifier("invite-preview-title")
                        .multilineTextAlignment(.leading)
                        .foregroundStyle(.colorTextPrimary)
                        .font(.callout.weight(.medium))
                        .truncationMode(.tail)
                    Text(description)
                        .font(.subheadline)
                        .accessibilityIdentifier(accessibilityDescriptionIdentifier)
                        .multilineTextAlignment(.leading)
                        .foregroundStyle(.colorTextSecondary)
                }

                if !isExpired,
                   let expiresAt = invite.conversationExpiresAt,
                   expiresAt > Date() {
                    Spacer()
                    ExplosionCountdownBadge(expiresAt: expiresAt)
                }
            }
            .padding(.vertical, DesignConstants.Spacing.step3x)
            .padding(.horizontal, DesignConstants.Spacing.step4x)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.colorFillSubtle)
        }
        .frame(maxWidth: 280.0, alignment: .leading)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("invite-preview-card")
        .cachedImage(for: invite) { image in
            cachedImage = image
        }
        .task {
            guard let imageURL = invite.imageURL else {
                return
            }

            do {
                let (data, _) = try await URLSession.shared.data(from: imageURL)
                if let image = UIImage(data: data) {
                    // Cache the image for future use
                    ImageCache.shared.cacheAfterUpload(image, for: invite, url: imageURL.absoluteString)
                    cachedImage = image
                }
            } catch {
                Log.error("Error loading image for invite")
            }
        }
    }
}

#Preview {
    MessageInviteView(invite: .mock)
        .frame(width: 200.0)
}
