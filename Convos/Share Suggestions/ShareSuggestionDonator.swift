import ConvosCore
import Intents
import SwiftUI
import UIKit

/// Donates an `INSendMessageIntent` per conversation so iOS surfaces them as
/// Sharing Suggestions - the contact/conversation row at the top of the share
/// sheet (like iMessage shows recent chats). The share extension reads the
/// chosen conversation back from `extensionContext.intent`.
///
/// Avatars: most conversation avatars are custom SwiftUI views (an emoji on a
/// colored background, or a monogram) rather than image files, so there is
/// nothing for iOS to display. We render the same `ConversationAvatarView` the
/// chats list uses into a `UIImage` and wrap it in an `INImage`. Photo-backed
/// avatars are pre-loaded and passed into the view so the snapshot shows the
/// photo instead of the emoji fallback.
enum ShareSuggestionDonator {
    private static let maxSuggestions: Int = 12
    private static let avatarSize: CGFloat = 120

    static func donate(_ conversations: [Conversation]) {
        // Only conversations with at least one other member are real share
        // targets; skip self-only / empty conversations.
        let targetable: [Conversation] = conversations.filter { conversation in
            conversation.members.contains { !$0.isCurrentUser }
        }
        Task { @MainActor in
            for conversation in targetable.prefix(maxSuggestions) {
                let photo: UIImage? = await ImageCache.shared.imageAsync(for: conversation)
                let avatar: INImage? = renderAvatar(for: conversation, photo: photo)
                submit(conversation: conversation, avatar: avatar)
            }
        }
    }

    @MainActor
    private static func renderAvatar(for conversation: Conversation, photo: UIImage?) -> INImage? {
        let avatarView = ConversationAvatarView(
            conversation: conversation,
            conversationImage: photo,
            size: avatarSize
        )
        .frame(width: avatarSize, height: avatarSize)
        let renderer: ImageRenderer = ImageRenderer(content: avatarView)
        renderer.scale = 3
        guard let image = renderer.uiImage, let data = image.pngData() else {
            return nil
        }
        return INImage(imageData: data)
    }

    private static func submit(conversation: Conversation, avatar: INImage?) {
        let title: String = conversation.title
        let displayName: String = title.isEmpty ? "Convo" : title
        let groupName: INSpeakableString = INSpeakableString(spokenPhrase: displayName)
        let recipient: INPerson = INPerson(
            personHandle: INPersonHandle(value: conversation.id, type: .unknown),
            nameComponents: nil,
            displayName: displayName,
            image: avatar,
            contactIdentifier: nil,
            customIdentifier: conversation.id
        )
        let intent: INSendMessageIntent = INSendMessageIntent(
            recipients: [recipient],
            outgoingMessageType: .outgoingMessageText,
            content: nil,
            speakableGroupName: groupName,
            conversationIdentifier: conversation.id,
            serviceName: "Convos",
            sender: nil,
            attachments: nil
        )
        if let avatar {
            intent.setImage(avatar, forParameterNamed: \.speakableGroupName)
        }
        let interaction: INInteraction = INInteraction(intent: intent, response: nil)
        interaction.direction = .outgoing
        interaction.groupIdentifier = conversation.id
        interaction.donate { error in
            if let error {
                Log.error("[ShareSuggestions] donate failed for \(conversation.id): \(error.localizedDescription)")
            }
        }
    }
}
