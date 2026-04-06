import Foundation
import UniformTypeIdentifiers

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
            case .linkPreview:
                if shouldShowSenderName {
                    text = "\(senderName) sent a link"
                } else {
                    text = "sent a link"
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
            case .linkPreview:
                if shouldShowSenderName {
                    text = "\(senderName) replied with a link"
                } else {
                    text = "replied with a link"
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
        var hasNonImage = false
        var primaryType: MediaType = .image
        var filename: String?

        for url in attachmentUrls {
            let classified = classifyAttachment(url)
            if classified.mediaType != .image {
                hasNonImage = true
                primaryType = classified.mediaType
            }
            if classified.filename != nil {
                filename = classified.filename
            }
        }

        if count <= 1 {
            if primaryType == .file, let filename { return filename }
            return primaryType.previewLabel
        }
        if hasNonImage { return "\(count) attachments" }
        return "\(count) photos"
    }

    private static func classifyAttachment(_ url: String) -> (mediaType: MediaType, filename: String?) {
        if let stored = try? StoredRemoteAttachment.fromJSON(url) {
            return classifyStoredAttachment(stored)
        } else if url.hasPrefix("file://") {
            return classifyFileURL(url)
        }
        return (.image, nil)
    }

    private static func classifyStoredAttachment(_ stored: StoredRemoteAttachment) -> (mediaType: MediaType, filename: String?) {
        if stored.mimeType?.hasPrefix("video/") == true {
            return (.video, stored.filename)
        } else if stored.mimeType?.hasPrefix("audio/") == true {
            return (.audio, stored.filename)
        } else if let mime = stored.mimeType, !mime.hasPrefix("image/") {
            return (.file, stored.filename)
        } else if let fn = stored.filename {
            let ext = (fn as NSString).pathExtension.lowercased()
            if !ext.isEmpty, let utType = UTType(filenameExtension: ext) {
                if utType.conforms(to: .movie) || utType.conforms(to: .video) {
                    return (.video, fn)
                } else if utType.conforms(to: .audio) {
                    return (.audio, fn)
                } else if !utType.conforms(to: .image) {
                    return (.file, fn)
                }
            }
        }
        return (.image, stored.filename)
    }

    private static func classifyFileURL(_ url: String) -> (mediaType: MediaType, filename: String?) {
        guard let fn = extractFilenameFromURL(url) else { return (.image, nil) }
        let ext = (fn as NSString).pathExtension.lowercased()
        guard !ext.isEmpty, let utType = UTType(filenameExtension: ext) else { return (.image, fn) }
        if utType.conforms(to: .movie) || utType.conforms(to: .video) {
            return (.video, fn)
        } else if utType.conforms(to: .audio) {
            return (.audio, fn)
        } else if !utType.conforms(to: .image) {
            return (.file, fn)
        }
        return (.image, fn)
    }

    private static func extractFilenameFromURL(_ url: String) -> String? {
        guard let parsed = URL(string: url) else { return nil }
        let lastComponent = parsed.lastPathComponent
        if let range = lastComponent.range(of: "_") {
            return String(lastComponent[range.upperBound...])
        }
        return lastComponent
    }
}
