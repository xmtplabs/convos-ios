import Foundation

extension DBLastMessageWithSource {
    func hydrateMessagePreview(
        conversationKind: ConversationKind,
        currentInboxId: String,
        members: [DBConversationMemberProfileWithRole]
    ) -> MessagePreview {
        let text: String
        let isCurrentUser = senderId == currentInboxId
        let senderProfile = members.first { $0.memberProfile.inboxId == senderId }
        let senderName = isCurrentUser ? "You" : (senderProfile?.memberProfile.name ?? "Somebody")
        let attachmentsCount = attachmentUrls.count
        let attachmentsString = Self.attachmentsPreviewString(attachmentUrls: attachmentUrls, count: attachmentsCount)

        let otherMemberCount = members.filter { $0.memberProfile.inboxId != currentInboxId }.count
        let shouldShowSenderName = conversationKind == .group && otherMemberCount > 1

        switch messageType {
        case .original:
            switch contentType {
            case .attachments:
                if shouldShowSenderName {
                    text = "\(senderName) sent \(attachmentsString)"
                } else {
                    text = "sent \(attachmentsString)"
                }
            case .text:
                if shouldShowSenderName {
                    text = "\(senderName): \(self.text ?? "")"
                } else {
                    text = self.text ?? ""
                }
            case .emoji:
                if shouldShowSenderName {
                    text = "\(senderName): \(self.emoji ?? "")"
                } else {
                    text = self.emoji ?? ""
                }
            case .update:
                if shouldShowSenderName {
                    text = "\(senderName) updated the group"
                } else {
                    text = "updated the group"
                }
            case .invite:
                if shouldShowSenderName {
                    text = "\(senderName) sent an invite"
                } else {
                    text = "sent an invite"
                }
            case .assistantJoinRequest:
                text = ""
            }

        case .reply:
            switch contentType {
            case .attachments:
                if shouldShowSenderName {
                    text = "\(senderName) replied with \(attachmentsString)"
                } else {
                    text = "replied with \(attachmentsString)"
                }
            case .text, .emoji:
                let replyText = self.text ?? self.emoji ?? ""
                if shouldShowSenderName {
                    text = "\(senderName): \(replyText)"
                } else {
                    text = replyText
                }
            case .update:
                text = ""
            case .invite:
                if shouldShowSenderName {
                    text = "\(senderName) replied with an invite"
                } else {
                    text = "replied with an invite"
                }
            case .assistantJoinRequest:
                text = ""
            }

        case .reaction:
            let reactionEmoji = emoji ?? "👍"
            let sourceText = sourceMessageText.formattedAsReactionSource()
            if shouldShowSenderName {
                text = "\(senderName) \(reactionEmoji)'d \(sourceText)"
            } else {
                text = "\(reactionEmoji)'d \(sourceText)"
            }
        }
        return .init(text: text, createdAt: date)
    }

    static func attachmentsPreviewString(attachmentUrls: [String], count: Int) -> String {
        var hasVideo = false
        var hasFile = false
        var filename: String?

        for url in attachmentUrls {
            if let stored = try? StoredRemoteAttachment.fromJSON(url) {
                if stored.mimeType?.hasPrefix("video/") == true {
                    hasVideo = true
                } else if let mime = stored.mimeType, !mime.hasPrefix("image/") {
                    hasFile = true
                    filename = stored.filename
                } else if let fn = stored.filename, !fn.hasSuffix(".jpg") && !fn.hasSuffix(".jpeg") && !fn.hasSuffix(".png") && !fn.hasSuffix(".heic") && !fn.hasSuffix(".gif") && !fn.hasSuffix(".webp") {
                    hasFile = true
                    filename = fn
                }
            }
        }

        if count <= 1 {
            if hasFile, let filename { return filename }
            if hasFile { return "a file" }
            if hasVideo { return "a video" }
            return "a photo"
        }
        if hasFile || hasVideo { return "\(count) attachments" }
        return "\(count) photos"
    }
}
