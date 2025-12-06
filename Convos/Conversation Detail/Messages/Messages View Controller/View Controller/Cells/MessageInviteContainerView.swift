import ConvosCore
import SwiftUI

struct MessageInviteContainerView: View {
    let invite: MessageInvite
    let style: MessageBubbleType
    let isOutgoing: Bool
    let profile: Profile
    let onTapInvite: ((MessageInvite) -> Void)
    let onTapAvatar: (() -> Void)?

    private var textColor: Color {
        // Match the text color based on message type (same as MessageContainer)
        if isOutgoing {
            return Color.colorTextPrimaryInverted
        } else {
            return Color.colorTextPrimary
        }
    }

    var body: some View {
        MessageContainer(style: style, isOutgoing: isOutgoing) {
            Button {
                onTapInvite(invite)
            } label: {
                MessageInviteView(invite: invite)
            }
        }
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
        }
        .padding(.horizontal, DesignConstants.Spacing.step2x)
    }
}

struct MessageInviteView: View {
    let invite: MessageInvite
    @State private var cachedImage: UIImage?

    var title: String {
        if let name = invite.conversationName, !name.isEmpty {
            return "Pop into my convo \"\(name)\""
        }
        return "Pop into my convo before it explodes"
    }

    var description: String {
        if let description = invite.conversationDescription, !description.isEmpty {
            return description
        }
        return "convos.org"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0.0) {
            Group {
                if let image = cachedImage {
                    Image(uiImage: image)
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                } else {
                    Image("convosIconLarge")
                        .resizable()
                        .tint(.colorTextPrimaryInverted)
                        .foregroundStyle(.colorTextPrimaryInverted)
                        .aspectRatio(contentMode: .fit)
                        .frame(height: 76.0, alignment: .center)
                        .frame(maxWidth: .infinity)
                }
            }
            .frame(height: 172.0)
            .clipped()
            .background(.colorBackgroundInverted)

            VStack(alignment: .leading, spacing: 2.0) {
                Text(title)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
                    .foregroundStyle(.black)
                    .font(.callout.weight(.bold))
                    .fontWeight(.bold)
                    .truncationMode(.tail)
                Text(description)
                    .font(.subheadline)
                    .multilineTextAlignment(.leading)
                    .foregroundStyle(.colorTextSecondary)
            }
            .padding(.vertical, DesignConstants.Spacing.step3x)
            .padding(.horizontal, DesignConstants.Spacing.step4x)
            .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: 280.0, alignment: .leading)
        .background(.colorLinkBackground)
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
                    ImageCache.shared.setImage(image, for: invite)
                    cachedImage = image
                }
            } catch {
                Log.error("Error loading image for invite")
                cachedImage = nil
            }
        }
    }
}

#Preview {
    MessageInviteView(invite: .mock)
        .frame(width: 200.0)
}
