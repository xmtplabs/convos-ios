import ConvosMessagingProtocols
import Foundation

/// Normalized decoded-payload shapes for the content types that the
/// storage layer needs to translate into `DBMessage`.
///
/// The storage-side translator
/// (`MessagingMessage+DBRepresentation.swift`) only sees the Convos-
/// owned values below; the boundary that decodes XIP structs into
/// these shapes lives in `XMTP DB Representations/MessagingMessage+XMTPiOS.swift`.
///
/// Scope note: this enum only carries the fields the storage layer
/// inspects today. Custom-codec consumers (push-notification preview,
/// `MessagingService+PushNotifications.swift`, outgoing-message path
/// in `OutgoingMessageWriter.swift`) still pull the raw XIP payloads
/// via `MessagingMessage.content<T>()`. Generalising this enum into a
/// full Convos-owned codec surface is the next iteration; for now the
/// narrow shape keeps the DB translator XMTPiOS-free without re-stating
/// every XIP payload.
public enum MessagingMessagePayload: Sendable {
    /// XIP `text:1.0` — a raw string body.
    case text(String)

    /// XIP `reply:1.0` — a quoted source message plus an inner payload
    /// the storage layer recursively inspects.
    case reply(MessagingReplyPayload)

    /// XIP `reaction:1.0` / `reaction:2.0` — already abstracted via
    /// `MessagingReaction`; the storage layer reads `emoji` +
    /// `reference` off this value.
    case reaction(MessagingReaction)

    /// XIP `attachment:1.0` — inline bytes + filename, persisted to the
    /// caches directory by the storage layer.
    case attachment(MessagingAttachmentPayload)

    /// XIP `remoteStaticAttachment:1.0` — a remote URL plus the
    /// decryption material needed by the attachment loader.
    case remoteAttachment(MessagingRemoteAttachmentPayload)

    /// XIP `multiRemoteStaticAttachment:1.0` — multiple remote
    /// attachments sent as a single message.
    case multiRemoteAttachment([MessagingRemoteAttachmentPayload])

    /// XIP `group_updated:1.0` — group membership / metadata change
    /// event emitted by the MLS stack.
    case groupUpdated(MessagingGroupUpdatedPayload)

    /// `convos.org/explode_settings:1.0` — the conversation-exploding
    /// timestamp. Convos-owned content type.
    case explodeSettings(ExplodeSettings)

    /// `convos.org/assistant_join_request:1.0` — invite-flow event.
    /// Convos-owned content type.
    case assistantJoinRequest(AssistantJoinRequest)

    /// XIP `readReceipt:1.0` — intentionally unsupported by the DB
    /// translator; the caller threw
    /// `.unsupportedContentType` for these before the migration.
    case readReceipt

    /// Content types not enumerated above. The DB translator rejects
    /// these as `.unsupportedContentType`, matching prior behavior.
    case unsupported
}

// MARK: - Inner payload types

/// Convos-owned mirror of the XIP `Reply` payload subset the storage
/// layer cares about.
public struct MessagingReplyPayload: Sendable {
    /// Source message id this reply quotes (`Reply.reference`).
    public let reference: String

    /// The inner content type — used to route the translator through
    /// text / attachment / remote-attachment sub-handlers. Carried as
    /// `MessagingContentType` so the abstraction layer does the
    /// comparison, not XMTPiOS.
    public let innerContentType: MessagingContentType

    /// The decoded inner payload. The translator only recurses into a
    /// few known shapes; everything else falls through to a `.text`
    /// placeholder, preserving prior logging behavior.
    public let innerPayload: MessagingReplyInnerPayload

    public init(
        reference: String,
        innerContentType: MessagingContentType,
        innerPayload: MessagingReplyInnerPayload
    ) {
        self.reference = reference
        self.innerContentType = innerContentType
        self.innerPayload = innerPayload
    }
}

/// Subset of reply-inner payload shapes the storage translator knows
/// how to store. Anything outside this enum falls through to the
/// "unhandled reply content type" log line and a text-shaped DB row
/// with no body.
public enum MessagingReplyInnerPayload: Sendable {
    case text(String)
    case attachment(MessagingAttachmentPayload)
    case remoteAttachment(MessagingRemoteAttachmentPayload)
    case other
}

/// Inline attachment payload — mirrors the subset of
/// `XMTPiOS.Attachment` the DB translator reads.
public struct MessagingAttachmentPayload: Sendable {
    public let data: Data
    public let filename: String
    public let mimeType: String

    public init(data: Data, filename: String, mimeType: String) {
        self.data = data
        self.filename = filename
        self.mimeType = mimeType
    }
}

/// Remote attachment payload — mirrors the subset of
/// `XMTPiOS.RemoteAttachment` the DB translator reads. `filename` is
/// optional because `RemoteAttachment.filename` is too.
public struct MessagingRemoteAttachmentPayload: Sendable {
    public let url: String
    public let contentDigest: String
    public let secret: Data
    public let salt: Data
    public let nonce: Data
    public let filename: String?

    public init(
        url: String,
        contentDigest: String,
        secret: Data,
        salt: Data,
        nonce: Data,
        filename: String?
    ) {
        self.url = url
        self.contentDigest = contentDigest
        self.secret = secret
        self.salt = salt
        self.nonce = nonce
        self.filename = filename
    }
}

/// Group-updated payload — exposes just the fields the DB translator
/// copies onto `DBMessage.Update`. Nested in this shape so the
/// abstraction layer does not depend on `XMTPiOS.GroupUpdated`.
public struct MessagingGroupUpdatedPayload: Sendable {
    public let initiatedByInboxId: String
    public let addedInboxIds: [String]
    public let removedInboxIds: [String]
    public let metadataFieldChanges: [MetadataFieldChange]

    public init(
        initiatedByInboxId: String,
        addedInboxIds: [String],
        removedInboxIds: [String],
        metadataFieldChanges: [MetadataFieldChange]
    ) {
        self.initiatedByInboxId = initiatedByInboxId
        self.addedInboxIds = addedInboxIds
        self.removedInboxIds = removedInboxIds
        self.metadataFieldChanges = metadataFieldChanges
    }

    public struct MetadataFieldChange: Sendable {
        public let fieldName: String
        public let oldValue: String?
        public let newValue: String?

        public init(fieldName: String, oldValue: String?, newValue: String?) {
            self.fieldName = fieldName
            self.oldValue = oldValue
            self.newValue = newValue
        }
    }
}
