import ConvosAppData
import Foundation
import GRDB
import UniformTypeIdentifiers

// MARK: - Emoji helpers

extension Character {
    var isSimpleEmoji: Bool {
        guard let firstScalar = unicodeScalars.first else { return false }
        return firstScalar.properties.isEmoji && firstScalar.value >= 0x231A
    }

    var isCombinedIntoEmoji: Bool {
        unicodeScalars.count > 1 && unicodeScalars.first?.properties.isEmoji ?? false
    }

    var isEmoji: Bool {
        isSimpleEmoji || isCombinedIntoEmoji
    }
}

extension String {
    var allCharactersEmoji: Bool {
        let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
        return !trimmed.isEmpty && !trimmed.contains { !$0.isEmoji }
    }
}

// MARK: - Translator

/// Stage 3 migration (audit §5): the content-type dispatch that
/// produces a `DBMessage` from an incoming message now operates on
/// `MessagingMessage` (and its resolved `MessagingMessagePayload`)
/// rather than on `XMTPiOS.DecodedMessage` directly.
///
/// The boundary from XMTPiOS -> abstraction lives in
/// `Storage/XMTP DB Representations/MessagingMessage+XMTPiOS.swift`.
/// This file is Foundation-only and contains the abstraction-side
/// logic — what DTU will also exercise in Stage 5.
extension MessagingMessage {
    enum DBRepresentationError: Error {
        case mismatchedContentType
        case unsupportedContentType
    }

    fileprivate struct DBMessageComponents {
        var messageType: DBMessageType
        var contentType: MessageContentType
        var sourceMessageId: String?
        var emoji: String?
        var invite: MessageInvite?
        var linkPreview: LinkPreview?
        var attachmentUrls: [String]
        var text: String?
        var update: DBMessage.Update?
    }

    /// Builds the GRDB `DBMessage` row for this message.
    ///
    /// The `payload` argument is expected to come from the boundary
    /// adapter (see `MessagingMessage.resolvedPayload()` in
    /// `Storage/XMTP DB Representations/MessagingMessage+XMTPiOS.swift`).
    /// Accepting it as an argument lets this file stay Foundation-only
    /// — the XIP decoding step is performed outside.
    func dbRepresentation(payload: MessagingMessagePayload) throws -> DBMessage {
        // Stage 2 migration: derive the DB status from the
        // abstraction-layer `MessagingDeliveryStatus` rather than from
        // `XMTPiOS.MessageDeliveryStatus` directly.
        let status: MessageStatus = deliveryStatus.status

        let components: DBMessageComponents
        switch payload {
        case .text(let text):
            components = Self.handleTextContent(text: text)
        case .reply(let reply):
            components = try Self.handleReplyContent(
                reply: reply,
                messageId: id
            )
        case .reaction(let reaction):
            components = Self.handleReactionContent(reaction: reaction)
        case .attachment(let attachment):
            components = try Self.handleAttachmentContent(
                attachment: attachment,
                messageId: id
            )
        case .remoteAttachment(let remoteAttachment):
            components = Self.handleRemoteAttachmentContent(
                remoteAttachment: remoteAttachment
            )
        case .multiRemoteAttachment(let remoteAttachments):
            components = Self.handleMultiRemoteAttachmentContent(
                remoteAttachments: remoteAttachments
            )
        case .groupUpdated(let groupUpdated):
            components = Self.handleGroupUpdatedContent(groupUpdated: groupUpdated)
        case .explodeSettings(let explodeSettings):
            components = Self.handleExplodeSettingsContent(
                explodeSettings: explodeSettings,
                senderInboxId: senderInboxId
            )
        case .assistantJoinRequest(let request):
            components = Self.handleAssistantJoinRequestContent(request: request)
        case .readReceipt:
            throw DBRepresentationError.unsupportedContentType
        case .unsupported:
            throw DBRepresentationError.unsupportedContentType
        }

        return DBMessage(
            id: id,
            clientMessageId: id,
            conversationId: conversationId,
            senderId: senderInboxId,
            dateNs: sentAtNs,
            date: sentAt,
            sortId: nil, // Will be assigned on save - existing message's sortId preserved
            status: status,
            messageType: components.messageType,
            contentType: components.contentType,
            text: components.text,
            emoji: components.emoji,
            invite: components.invite,
            linkPreview: components.linkPreview,
            sourceMessageId: components.sourceMessageId,
            attachmentUrls: components.attachmentUrls,
            update: components.update
        )
    }

    // MARK: - Per-payload handlers

    private static func handleTextContent(text: String) -> DBMessageComponents {
        let isContentEmoji = text.allCharactersEmoji
        if !isContentEmoji, let invite = MessageInvite.from(text: text) {
            return DBMessageComponents(
                messageType: .original,
                contentType: .invite,
                sourceMessageId: nil,
                emoji: nil,
                invite: invite,
                attachmentUrls: [],
                text: text,
                update: nil
            )
        } else if !isContentEmoji, let preview = LinkPreview.from(text: text) {
            return DBMessageComponents(
                messageType: .original,
                contentType: .linkPreview,
                sourceMessageId: nil,
                emoji: nil,
                invite: nil,
                linkPreview: preview,
                attachmentUrls: [],
                text: text,
                update: nil
            )
        } else {
            let trimmedContent = text.trimmingCharacters(in: .whitespacesAndNewlines)
            return DBMessageComponents(
                messageType: .original,
                contentType: isContentEmoji ? .emoji : .text,
                sourceMessageId: nil,
                emoji: isContentEmoji ? trimmedContent : nil,
                attachmentUrls: [],
                text: isContentEmoji ? nil : text,
                update: nil
            )
        }
    }

    private static func handleReplyContent(
        reply: MessagingReplyPayload,
        messageId: String
    ) throws -> DBMessageComponents {
        let sourceMessageId = reply.reference
        switch reply.innerPayload {
        case .text(let contentString):
            let isContentEmoji = contentString.allCharactersEmoji
            if !isContentEmoji, let invite = MessageInvite.from(text: contentString) {
                return DBMessageComponents(
                    messageType: .reply,
                    contentType: .invite,
                    sourceMessageId: sourceMessageId,
                    emoji: nil,
                    invite: invite,
                    attachmentUrls: [],
                    text: contentString,
                    update: nil
                )
            }
            if !isContentEmoji, let preview = LinkPreview.from(text: contentString) {
                return DBMessageComponents(
                    messageType: .reply,
                    contentType: .linkPreview,
                    sourceMessageId: sourceMessageId,
                    emoji: nil,
                    invite: nil,
                    linkPreview: preview,
                    attachmentUrls: [],
                    text: contentString,
                    update: nil
                )
            }
            let trimmedContent = contentString.trimmingCharacters(in: .whitespacesAndNewlines)
            return DBMessageComponents(
                messageType: .reply,
                contentType: isContentEmoji ? .emoji : .text,
                sourceMessageId: sourceMessageId,
                emoji: isContentEmoji ? trimmedContent : nil,
                attachmentUrls: [],
                text: isContentEmoji ? nil : contentString,
                update: nil
            )
        case .attachment(let attachment):
            let fileURL = try saveInlineAttachment(
                data: attachment.data,
                messageId: messageId,
                filename: attachment.filename
            )
            return DBMessageComponents(
                messageType: .reply,
                contentType: .attachments,
                sourceMessageId: sourceMessageId,
                emoji: nil,
                attachmentUrls: [fileURL.absoluteString],
                text: nil,
                update: nil
            )
        case .remoteAttachment(let remoteAttachment):
            let stored = StoredRemoteAttachment(
                url: remoteAttachment.url,
                contentDigest: remoteAttachment.contentDigest,
                secret: remoteAttachment.secret,
                salt: remoteAttachment.salt,
                nonce: remoteAttachment.nonce,
                filename: remoteAttachment.filename
            )
            let json = (try? stored.toJSON()) ?? remoteAttachment.url
            return DBMessageComponents(
                messageType: .reply,
                contentType: .attachments,
                sourceMessageId: sourceMessageId,
                emoji: nil,
                attachmentUrls: [json],
                text: nil,
                update: nil
            )
        case .other:
            Log.error("Unhandled reply inner content type \(reply.innerContentType)")
            return DBMessageComponents(
                messageType: .reply,
                contentType: .text,
                sourceMessageId: sourceMessageId,
                emoji: nil,
                attachmentUrls: [],
                text: nil,
                update: nil
            )
        }
    }

    private static func handleReactionContent(
        reaction: MessagingReaction
    ) -> DBMessageComponents {
        // Stage 2 migration: derive the emoji glyph through the
        // abstraction-layer `MessagingReaction` rather than from
        // `XMTPiOS.Reaction` directly.
        DBMessageComponents(
            messageType: .reaction,
            contentType: .emoji,
            sourceMessageId: reaction.reference,
            emoji: reaction.emoji,
            attachmentUrls: [],
            text: nil,
            update: nil
        )
    }

    private static func handleAttachmentContent(
        attachment: MessagingAttachmentPayload,
        messageId: String
    ) throws -> DBMessageComponents {
        let fileURL = try saveInlineAttachment(
            data: attachment.data,
            messageId: messageId,
            filename: attachment.filename
        )
        return DBMessageComponents(
            messageType: .original,
            contentType: .attachments,
            sourceMessageId: nil,
            emoji: nil,
            attachmentUrls: [fileURL.absoluteString],
            text: nil,
            update: nil
        )
    }

    private static func saveInlineAttachment(
        data: Data,
        messageId: String,
        filename: String
    ) throws -> URL {
        guard let cacheDir = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first else {
            throw DBRepresentationError.mismatchedContentType
        }
        let dir = cacheDir.appendingPathComponent("InlineAttachments", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let safeFilename = "\(messageId)_\(filename)".replacingOccurrences(of: "/", with: "_")
        let fileURL = dir.appendingPathComponent(safeFilename)
        try data.write(to: fileURL, options: .atomic)
        return fileURL
    }

    private static func handleMultiRemoteAttachmentContent(
        remoteAttachments: [MessagingRemoteAttachmentPayload]
    ) -> DBMessageComponents {
        let storedAttachments = remoteAttachments.map { attachment in
            let inferredMimeType: String? = attachment.filename.flatMap { filename in
                let ext = (filename as NSString).pathExtension.lowercased()
                guard !ext.isEmpty else { return nil }
                return UTType(filenameExtension: ext)?.preferredMIMEType
            }
            let stored = StoredRemoteAttachment(
                url: attachment.url,
                contentDigest: attachment.contentDigest,
                secret: attachment.secret,
                salt: attachment.salt,
                nonce: attachment.nonce,
                filename: attachment.filename,
                mimeType: inferredMimeType
            )
            return (try? stored.toJSON()) ?? attachment.url
        }
        return DBMessageComponents(
            messageType: .original,
            contentType: .attachments,
            sourceMessageId: nil,
            emoji: nil,
            attachmentUrls: storedAttachments,
            text: nil,
            update: nil
        )
    }

    private static func handleRemoteAttachmentContent(
        remoteAttachment: MessagingRemoteAttachmentPayload
    ) -> DBMessageComponents {
        let inferredMimeType: String? = remoteAttachment.filename.flatMap { filename in
            let ext = (filename as NSString).pathExtension.lowercased()
            guard !ext.isEmpty else { return nil }
            return UTType(filenameExtension: ext)?.preferredMIMEType
        }
        let stored = StoredRemoteAttachment(
            url: remoteAttachment.url,
            contentDigest: remoteAttachment.contentDigest,
            secret: remoteAttachment.secret,
            salt: remoteAttachment.salt,
            nonce: remoteAttachment.nonce,
            filename: remoteAttachment.filename,
            mimeType: inferredMimeType
        )
        let json = (try? stored.toJSON()) ?? remoteAttachment.url
        return DBMessageComponents(
            messageType: .original,
            contentType: .attachments,
            sourceMessageId: nil,
            emoji: nil,
            attachmentUrls: [json],
            text: nil,
            update: nil
        )
    }

    private static func handleGroupUpdatedContent(
        groupUpdated: MessagingGroupUpdatedPayload
    ) -> DBMessageComponents {
        let metadataFieldChanges: [DBMessage.Update.MetadataChange] = groupUpdated
            .metadataFieldChanges
            .compactMap { change in
                if change.fieldName == ConversationUpdate.MetadataChange.Field.description.rawValue {
                    let descriptionChanged = change.oldValue != change.newValue
                    if descriptionChanged {
                        return .init(
                            field: ConversationUpdate.MetadataChange.Field.description.rawValue,
                            oldValue: change.oldValue,
                            newValue: change.newValue
                        )
                    } else {
                        return .init(
                            field: ConversationUpdate.MetadataChange.Field.unknown.rawValue,
                            oldValue: nil,
                            newValue: nil
                        )
                    }
                } else if change.fieldName == ConversationUpdate.MetadataChange.Field.metadata.rawValue {
                    let oldCustomValue: ConversationCustomMetadata?
                    if let oldValue = change.oldValue {
                        do {
                            oldCustomValue = try ConversationCustomMetadata.fromCompactString(oldValue)
                        } catch {
                            Log.error("Failed to decode old custom metadata: \(error)")
                            oldCustomValue = nil
                        }
                    } else {
                        oldCustomValue = nil
                    }

                    let newCustomValue: ConversationCustomMetadata?
                    if let newValue = change.newValue {
                        do {
                            newCustomValue = try ConversationCustomMetadata.fromCompactString(newValue)
                        } catch {
                            Log.error("Failed to decode new custom metadata: \(error)")
                            newCustomValue = nil
                        }
                    } else {
                        newCustomValue = nil
                    }

                    // Extract expiresAt values (only if explicitly set)
                    let oldExpiresAt: Date?
                    if let oldCustomValue, oldCustomValue.hasExpiresAtUnix {
                        oldExpiresAt = Date(timeIntervalSince1970: TimeInterval(oldCustomValue.expiresAtUnix))
                    } else {
                        oldExpiresAt = nil
                    }

                    let newExpiresAt: Date?
                    if let newCustomValue, newCustomValue.hasExpiresAtUnix {
                        newExpiresAt = Date(timeIntervalSince1970: TimeInterval(newCustomValue.expiresAtUnix))
                    } else {
                        newExpiresAt = nil
                    }

                    let expiresAtChanged = oldExpiresAt != newExpiresAt
                    // Skip expiresAt changes - these are handled by ExplodeSettings content type
                    if expiresAtChanged {
                        return .init(
                            field: ConversationUpdate.MetadataChange.Field.unknown.rawValue,
                            oldValue: nil,
                            newValue: nil
                        )
                    } else {
                        // some other custom field changed (tag, profiles, etc.)
                        return .init(
                            field: ConversationUpdate.MetadataChange.Field.metadata.rawValue,
                            oldValue: nil,
                            newValue: nil
                        )
                    }
                } else {
                    return .init(
                        field: change.fieldName,
                        oldValue: change.oldValue,
                        newValue: change.newValue
                    )
                }
            }
        let update = DBMessage.Update(
            initiatedByInboxId: groupUpdated.initiatedByInboxId,
            addedInboxIds: groupUpdated.addedInboxIds,
            removedInboxIds: groupUpdated.removedInboxIds,
            metadataChanges: metadataFieldChanges,
            expiresAt: nil
        )
        return DBMessageComponents(
            messageType: .original,
            contentType: .update,
            sourceMessageId: nil,
            emoji: nil,
            attachmentUrls: [],
            text: nil,
            update: update
        )
    }

    private static func handleAssistantJoinRequestContent(
        request: AssistantJoinRequest
    ) -> DBMessageComponents {
        DBMessageComponents(
            messageType: .original,
            contentType: .assistantJoinRequest,
            sourceMessageId: nil,
            emoji: nil,
            attachmentUrls: [],
            text: request.status.rawValue,
            update: nil
        )
    }

    private static func handleExplodeSettingsContent(
        explodeSettings: ExplodeSettings,
        senderInboxId: String
    ) -> DBMessageComponents {
        Log.info("Received explode settings: \(explodeSettings)")
        let update = DBMessage.Update(
            initiatedByInboxId: senderInboxId,
            addedInboxIds: [],
            removedInboxIds: [],
            metadataChanges: [],
            expiresAt: explodeSettings.expiresAt
        )

        return DBMessageComponents(
            messageType: .original,
            contentType: .update,
            sourceMessageId: nil,
            emoji: nil,
            attachmentUrls: [],
            text: nil,
            update: update
        )
    }
}
