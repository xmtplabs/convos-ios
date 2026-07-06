import Foundation
import UniformTypeIdentifiers

extension DBLastMessageWithSource {
    private var connectionEventSummaryText: String {
        guard let text,
              let data = text.data(using: .utf8),
              let summary = try? JSONDecoder().decode(ConnectionEventSummary.self, from: data) else {
            return text ?? ""
        }
        return summary.text
    }

    func hydrateMessagePreview(
        conversationKind: ConversationKind,
        currentInboxId: String,
        members: [DBConversationMemberProfileWithRole],
        contactNameResolver: (String) -> String? = { _ in nil }
    ) -> MessagePreview {
        let text: String
        let isCurrentUser = senderId == currentInboxId
        let senderProfile = members.first { $0.memberProfile.inboxId == senderId }
        // Hoisted to a static helper so its branches don't count against
        // this function's cyclomatic complexity score, mirroring the same
        // pattern `resolvedMemberDisplayName` uses in ModelMocks.swift.
        let senderName = Self.resolveSenderName(
            isCurrentUser: isCurrentUser,
            inboxId: senderId,
            profile: senderProfile?.memberProfile,
            contactNameResolver: contactNameResolver
        )
        let attachmentsCount = attachmentUrls.count
        let attachmentsString = Self.attachmentsPreviewString(attachmentUrls: attachmentUrls, count: attachmentsCount)

        let otherMemberCount = members.filter { $0.memberProfile.inboxId != currentInboxId }.count
        let shouldShowSenderName = conversationKind == .group && otherMemberCount > 1

        switch messageType {
        case .original:
            switch contentType {
            case .attachments:
                text = Self.attachmentsPreviewText(
                    senderName: senderName,
                    senderIsAgent: !isCurrentUser && senderProfile?.memberProfile.isAgent == true,
                    attachmentUrls: attachmentUrls,
                    attachmentsString: attachmentsString,
                    otherMemberCount: otherMemberCount,
                    shouldShowSenderName: shouldShowSenderName
                )
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
            case .agentShare:
                if shouldShowSenderName {
                    text = "\(senderName) shared an agent"
                } else {
                    text = "shared an agent"
                }
            case .linkPreview:
                if shouldShowSenderName {
                    text = "\(senderName) sent a link"
                } else {
                    text = "sent a link"
                }
            case .assistantJoinRequest,
                 .connectionGrantRequest,
                 .capabilityRequest,
                 .capabilityRequestResult:
                text = ""
            case .connectionEvent, .connectionInvocation, .connectionInvocationResult, .connectionPayload:
                text = connectionEventSummaryText
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
            case .agentShare:
                if shouldShowSenderName {
                    text = "\(senderName) replied with an agent"
                } else {
                    text = "replied with an agent"
                }
            case .linkPreview:
                if shouldShowSenderName {
                    text = "\(senderName) replied with a link"
                } else {
                    text = "replied with a link"
                }
            case .assistantJoinRequest,
                 .connectionGrantRequest,
                 .capabilityRequest,
                 .capabilityRequestResult:
                text = ""
            case .connectionEvent, .connectionInvocation, .connectionInvocationResult, .connectionPayload:
                text = connectionEventSummaryText
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

    /// Resolves the sender's rendered name for a message preview row.
    /// Precedence: "You" for the local user, the per-conversation profile name
    /// when set, then the local contact name as a fallback, then "Agent" /
    /// "Somebody" keyed on `isAgent`. The contact name is fallback-only (it
    /// fills an empty name, it does not override a present one), matching the
    /// in-chat bubble. Hoisted out of `hydrateMessagePreview` so the extra
    /// branch doesn't push that function past the cyclomatic complexity
    /// threshold.
    private static func resolveSenderName(
        isCurrentUser: Bool,
        inboxId: String,
        profile: DBMemberProfile?,
        contactNameResolver: (String) -> String? = { _ in nil }
    ) -> String {
        if isCurrentUser { return "You" }
        if let name = profile?.name, !name.isEmpty { return name }
        if let contactName = contactNameResolver(inboxId), !contactName.isEmpty { return contactName }
        return profile?.isAgent == true ? "Agent" : "Somebody"
    }

    /// Builds the preview line for an attachment message. An agent sending a
    /// single html file gets bespoke copy ("made you a thing" / "made a thing
    /// for the group") instead of the generic "sent <filename>" line.
    static func attachmentsPreviewText(
        senderName: String,
        senderIsAgent: Bool,
        attachmentUrls: [String],
        attachmentsString: String,
        otherMemberCount: Int,
        shouldShowSenderName: Bool
    ) -> String {
        if senderIsAgent, isSingleHtmlAttachment(attachmentUrls) {
            return otherMemberCount > 1
                ? "\(senderName) made a thing for the group"
                : "\(senderName) made you a thing"
        }
        return shouldShowSenderName ? "\(senderName) sent \(attachmentsString)" : "sent \(attachmentsString)"
    }

    private static func isSingleHtmlAttachment(_ attachmentUrls: [String]) -> Bool {
        guard attachmentUrls.count == 1, let url = attachmentUrls.first else { return false }
        guard let filename = classifyAttachment(url).filename else { return false }
        let ext = (filename as NSString).pathExtension.lowercased()
        guard !ext.isEmpty, let utType = UTType(filenameExtension: ext) else { return false }
        return utType.conforms(to: .html)
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
