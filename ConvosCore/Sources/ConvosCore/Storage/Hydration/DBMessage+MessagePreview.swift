import Foundation

extension DBMessage {
    func hydrateMessagePreview(conversationKind: ConversationKind, currentInboxId: String) -> MessagePreview {
        let text: String
        let isCurrentUser = senderId == currentInboxId
        let senderString: String = isCurrentUser ? "You " : "Someone "
        let optionalSender: String = conversationKind == .group ? senderString : ""
        let attachmentsCount = attachmentUrls.count
        let attachmentsString = attachmentsCount <= 1 ? "a photo" : "\(attachmentsCount) photos"

        switch messageType {
        case .original:
            switch contentType {
            case .attachments:
                text = "\(optionalSender)sent \(attachmentsString)"
            case .text:
                text = self.text ?? ""
            case .emoji:
                text = self.emoji ?? ""
            case .update:
                text = "\(optionalSender)updated the group"
            case .invite:
                text = "\(optionalSender)sent an invite"
            }

        case .reply:
            let originalMessage: String = "original"
            switch contentType {
            case .attachments:
                text = "\(optionalSender)replied with \(attachmentsString)"
            case .text, .emoji:
                text = "\(optionalSender)replied: \(self.text ?? "") to \"\(originalMessage)\""
            case .update:
                text = ""
            case .invite:
                text = "\(optionalSender)replied with an invite"
            }

        case .reaction:
            text = "\(senderString)\(emoji.map { "reacted with \($0)" } ?? "reacted to a message")"
        }
        return .init(text: text, createdAt: date)
    }
}
