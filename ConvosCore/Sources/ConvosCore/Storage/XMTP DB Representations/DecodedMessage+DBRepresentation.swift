import Foundation
import GRDB
import XMTPiOS

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

extension XMTPiOS.DecodedMessage {
    enum DecodedMessageDBRepresentationError: Error {
        case mismatchedContentType, unsupportedContentType
    }

    private struct DBMessageComponents {
        var messageType: DBMessageType
        var contentType: MessageContentType
        var sourceMessageId: String?
        var emoji: String?
        var invite: MessageInvite?
        var attachmentUrls: [String]
        var text: String?
        var update: DBMessage.Update?
    }

    func dbRepresentation() throws -> DBMessage {
        let status: MessageStatus = deliveryStatus.status
        let encodedContentType = try encodedContent.type
        let components: DBMessageComponents

        switch encodedContentType {
        case ContentTypeText:
            components = try handleTextContent()
        case ContentTypeReply:
            components = try handleReplyContent()
        case ContentTypeReaction, ContentTypeReactionV2:
            components = try handleReactionContent()
        case ContentTypeMultiRemoteAttachment:
            components = try handleMultiRemoteAttachmentContent()
        case ContentTypeRemoteAttachment:
            components = try handleRemoteAttachmentContent()
        case ContentTypeGroupUpdated:
            components = try handleGroupUpdatedContent()
        case ContentTypeExplodeSettings:
            components = try handleExplodeSettingsContent()
        default:
            throw DecodedMessageDBRepresentationError.unsupportedContentType
        }

        return .init(
            id: id,
            clientMessageId: id,
            conversationId: conversationId,
            senderId: senderInboxId,
            dateNs: sentAtNs,
            date: sentAt,
            status: status,
            messageType: components.messageType,
            contentType: components.contentType,
            text: components.text,
            emoji: components.emoji,
            invite: components.invite,
            sourceMessageId: components.sourceMessageId,
            attachmentUrls: components.attachmentUrls,
            update: components.update
        )
    }

    private func handleTextContent() throws -> DBMessageComponents {
        let content = try content() as Any
        guard let contentString = content as? String else {
            throw DecodedMessageDBRepresentationError.mismatchedContentType
        }

        let isContentEmoji = contentString.allCharactersEmoji
        // try and decode the text as an invite
        if !isContentEmoji, let invite = MessageInvite.from(text: contentString) {
            return DBMessageComponents(
                messageType: .original,
                contentType: .invite,
                sourceMessageId: nil,
                emoji: nil,
                invite: invite,
                attachmentUrls: [],
                text: contentString,
                update: nil
            )
        } else {
            let trimmedContent = contentString.trimmingCharacters(in: .whitespacesAndNewlines)
            return DBMessageComponents(
                messageType: .original,
                contentType: isContentEmoji ? .emoji : .text,
                sourceMessageId: nil,
                emoji: isContentEmoji ? trimmedContent : nil,
                attachmentUrls: [],
                text: isContentEmoji ? nil : contentString,
                update: nil
            )
        }
    }

    private func handleReplyContent() throws -> DBMessageComponents {
        let content = try content() as Any
        guard let contentReply = content as? Reply else {
            throw DecodedMessageDBRepresentationError.mismatchedContentType
        }
        let sourceMessageId = contentReply.reference
        switch contentReply.contentType {
        case ContentTypeText:
            guard let contentString = contentReply.content as? String else {
                throw DecodedMessageDBRepresentationError.mismatchedContentType
            }
            return DBMessageComponents(
                messageType: .reply,
                contentType: .text,
                sourceMessageId: sourceMessageId,
                emoji: nil,
                attachmentUrls: [],
                text: contentString,
                update: nil
            )
        case ContentTypeRemoteAttachment:
            guard let remoteAttachment = content as? RemoteAttachment else {
                throw DecodedMessageDBRepresentationError.mismatchedContentType
            }
            return DBMessageComponents(
                messageType: .reply,
                contentType: .attachments,
                sourceMessageId: sourceMessageId,
                emoji: nil,
                attachmentUrls: [remoteAttachment.url],
                text: nil,
                update: nil
            )
        default:
            Log.error("Unhandled contentType \(contentReply.contentType)")
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

    private func handleReactionContent() throws -> DBMessageComponents {
        let content = try content() as Any
        guard let reaction = content as? Reaction else {
            throw DecodedMessageDBRepresentationError.mismatchedContentType
        }
        return DBMessageComponents(
            messageType: .reaction,
            contentType: .emoji,
            sourceMessageId: reaction.reference,
            emoji: reaction.emoji,
            attachmentUrls: [],
            text: nil,
            update: nil
        )
    }

    private func handleMultiRemoteAttachmentContent() throws -> DBMessageComponents {
        let content = try content() as Any
        guard let remoteAttachments = content as? [RemoteAttachment] else {
            throw DecodedMessageDBRepresentationError.mismatchedContentType
        }
        return DBMessageComponents(
            messageType: .original,
            contentType: .attachments,
            sourceMessageId: nil,
            emoji: nil,
            attachmentUrls: remoteAttachments.map { $0.url },
            text: nil,
            update: nil
        )
    }

    private func handleRemoteAttachmentContent() throws -> DBMessageComponents {
        let content = try content() as Any
        guard let remoteAttachment = content as? RemoteAttachment else {
            throw DecodedMessageDBRepresentationError.mismatchedContentType
        }
        return DBMessageComponents(
            messageType: .original,
            contentType: .attachments,
            sourceMessageId: nil,
            emoji: nil,
            attachmentUrls: [remoteAttachment.url],
            text: nil,
            update: nil
        )
    }

    private func handleGroupUpdatedContent() throws -> DBMessageComponents {
        let content = try content() as Any
        guard let groupUpdated = content as? GroupUpdated else {
            throw DecodedMessageDBRepresentationError.mismatchedContentType
        }
        let metadataFieldChanges: [DBMessage.Update.MetadataChange] = groupUpdated.metadataFieldChanges
            .compactMap {
                if $0.fieldName == ConversationUpdate.MetadataChange.Field.description.rawValue {
                    let descriptionChanged = $0.oldValue != $0.newValue
                    if descriptionChanged {
                        return .init(
                            field: ConversationUpdate.MetadataChange.Field.description.rawValue,
                            oldValue: $0.oldValue,
                            newValue: $0.newValue
                        )
                    } else {
                        return .init(
                            field: ConversationUpdate.MetadataChange.Field.unknown.rawValue,
                            oldValue: nil,
                            newValue: nil
                        )
                    }
                } else if $0.fieldName == ConversationUpdate.MetadataChange.Field.metadata.rawValue {
                    let oldCustomValue: ConversationCustomMetadata?
                    if $0.hasOldValue {
                        do {
                            oldCustomValue = try ConversationCustomMetadata.fromCompactString($0.oldValue)
                        } catch {
                            Log.error("Failed to decode old custom metadata: \(error)")
                            oldCustomValue = nil
                        }
                    } else {
                        oldCustomValue = nil
                    }

                    let newCustomValue: ConversationCustomMetadata?
                    if $0.hasNewValue {
                        do {
                            newCustomValue = try ConversationCustomMetadata.fromCompactString($0.newValue)
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
                    // Determine what to report based on what actually changed
                    if expiresAtChanged {
                        // expiresAt changed, prioritize it
                        return .init(
                            field: ConversationUpdate.MetadataChange.Field.expiresAt.rawValue,
                            oldValue: oldExpiresAt?.ISO8601Format(),
                            newValue: newExpiresAt?.ISO8601Format()
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
                        field: $0.fieldName,
                        oldValue: $0.hasOldValue ? $0.oldValue : nil,
                        newValue: $0.hasNewValue ? $0.newValue : nil
                    )
                }
            }
        let update = DBMessage.Update(
            initiatedByInboxId: groupUpdated.initiatedByInboxID,
            addedInboxIds: groupUpdated.addedInboxes.map { $0.inboxID },
            removedInboxIds: groupUpdated.removedInboxes.map { $0.inboxID },
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

    private func handleExplodeSettingsContent() throws -> DBMessageComponents {
        let content = try content() as Any
        guard let explodeSettings = content as? ExplodeSettings else {
            throw DecodedMessageDBRepresentationError.mismatchedContentType
        }

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
