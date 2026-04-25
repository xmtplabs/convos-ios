import ConvosMessagingProtocols
import Foundation
@preconcurrency import XMTPiOS

/// XMTPiOS -> abstraction boundary for `DecodedMessage`.
///
/// Stage 3 migration (audit §5): the dispatch on
/// `XMTPiOS.DecodedMessage.encodedContent.type` that produces a
/// `DBMessage` has moved onto `MessagingMessage` (see
/// `MessagingMessage+DBRepresentation.swift`). This file now only holds
/// the XMTPiOS -> Messaging boundary initializer and the XIP-payload
/// → `MessagingMessagePayload` bridge — analogous to the Stage 2
/// `MessageDeliveryStatus+DBRepresentation.swift` and
/// `Reaction+DBRepresentation.swift` translators.
///
/// Call sites that previously wrote `xmtpDecodedMessage.dbRepresentation()`
/// now write `MessagingMessage(xmtpDecodedMessage).dbRepresentation()`.
/// The one-hop indirection is the whole point: every storage / writer
/// call site is now expressed against `MessagingMessage`, and the DTU
/// adapter (Stage 5) will populate the same value type with no XMTPiOS
/// involvement.
///
/// `senderInstallationId` is populated as `nil` here: the pinned
/// XMTPiOS SDK does not yet surface it on `DecodedMessage` (only
/// `senderInboxId`). See the `MessagingMessage` type doc for the audit
/// open-question tracking.
extension MessagingMessage {
    /// Build a Convos-owned message from an XMTPiOS decoded message.
    ///
    /// Kept as the only XMTPiOS-aware surface of this mapping so the
    /// eventual DTU adapter can build `MessagingMessage` directly
    /// without re-implementing the storage translator.
    init(_ xmtpDecodedMessage: XMTPiOS.DecodedMessage) throws {
        let xmtpEncodedContent = try xmtpDecodedMessage.encodedContent
        let encodedContent = MessagingEncodedContent(xmtpEncodedContent)

        // Eagerly capture the decoded payload. `XMTPiOS.DecodedMessage`
        // caches its decoded content internally (see
        // `sdks/ios/Sources/XMTPiOS/Libxmtp/DecodedMessage.swift:150-157`),
        // so `content()` is just a cast. We snapshot it here so the
        // `MessagingMessage.contentDecoder` closure does not have to
        // capture the non-Sendable `DecodedMessage`.
        //
        // If decoding fails (e.g. `readReceipt` rows where XMTPiOS
        // returns `Any` but the translator dispatches on type anyway)
        // we fall back to `NSNull()` and let the translator's
        // `encodedContent.type` switch decide what to do.
        let decodedAny: Any = (try? xmtpDecodedMessage.content() as Any) ?? NSNull()
        let decodedBox: _MessagingDecodedPayloadBox = _MessagingDecodedPayloadBox(
            payload: decodedAny
        )

        self.init(
            id: xmtpDecodedMessage.id,
            conversationId: xmtpDecodedMessage.conversationId,
            senderInboxId: xmtpDecodedMessage.senderInboxId,
            senderInstallationId: nil,
            sentAt: xmtpDecodedMessage.sentAt,
            sentAtNs: xmtpDecodedMessage.sentAtNs,
            insertedAt: xmtpDecodedMessage.insertedAt,
            insertedAtNs: xmtpDecodedMessage.insertedAtNs,
            expiresAtNs: xmtpDecodedMessage.expiresAtNs,
            deliveryStatus: MessagingDeliveryStatus(xmtpDecodedMessage.deliveryStatus),
            encodedContent: encodedContent,
            childMessages: xmtpDecodedMessage.childMessages?.compactMap { child in
                try? MessagingMessage(child)
            },
            contentDecoder: { _ in decodedBox.payload }
        )
    }
}

// MARK: - Payload resolution (XIP -> MessagingMessagePayload)

extension MessagingMessage {
    /// Turn the XIP-decoded `content()` result into a
    /// `MessagingMessagePayload` the storage translator can dispatch
    /// on without importing XMTPiOS.
    ///
    /// Lives on the boundary side because it must cast to `Reply`,
    /// `Reaction`, `Attachment`, `RemoteAttachment`, and `GroupUpdated`
    /// — all XMTPiOS-owned XIP payload types today. When Stage 6
    /// re-states these as Convos structs this helper becomes a pure
    /// pass-through.
    ///
    /// The high branch count is inherent: every supported XIP content
    /// type needs its own cast. Splitting into per-type helpers trades
    /// one long function for a dispatch wrapper plus ten trivial
    /// helpers, which is strictly worse for the reader. Disabling the
    /// lint for this one function.
    // swiftlint:disable:next cyclomatic_complexity
    func resolvedPayload() -> MessagingMessagePayload {
        let contentType = encodedContent.type

        // Reactions: prefer the already-abstracted `MessagingReaction`.
        // Matches prior `handleReactionContent()` behavior.
        if contentType == .reaction || contentType == .reactionV2 {
            guard let xmtpReaction = (try? content() as XMTPiOS.Reaction) else {
                return .unsupported
            }
            return .reaction(MessagingReaction(xmtpReaction))
        }

        if contentType == .text {
            guard let string = (try? content() as String) else {
                return .unsupported
            }
            return .text(string)
        }

        if contentType == .reply {
            guard let xmtpReply = (try? content() as XMTPiOS.Reply) else {
                return .unsupported
            }
            return .reply(MessagingReplyPayload(xmtpReply))
        }

        if contentType == .attachment {
            guard let xmtpAttachment = (try? content() as XMTPiOS.Attachment) else {
                return .unsupported
            }
            return .attachment(MessagingAttachmentPayload(xmtpAttachment))
        }

        if contentType == .remoteAttachment {
            guard let xmtpRemoteAttachment = (try? content() as XMTPiOS.RemoteAttachment) else {
                return .unsupported
            }
            return .remoteAttachment(
                MessagingRemoteAttachmentPayload(xmtpRemoteAttachment)
            )
        }

        if contentType == .multiRemoteAttachment {
            guard let xmtpAttachments = (try? content() as [XMTPiOS.RemoteAttachment]) else {
                return .unsupported
            }
            return .multiRemoteAttachment(
                xmtpAttachments.map(MessagingRemoteAttachmentPayload.init)
            )
        }

        if contentType == .groupUpdated {
            guard let xmtpGroupUpdated = (try? content() as XMTPiOS.GroupUpdated) else {
                return .unsupported
            }
            return .groupUpdated(MessagingGroupUpdatedPayload(xmtpGroupUpdated))
        }

        if contentType == .explodeSettings {
            guard let explodeSettings = (try? content() as ExplodeSettings) else {
                return .unsupported
            }
            return .explodeSettings(explodeSettings)
        }

        if contentType == .assistantJoinRequest {
            guard let request = (try? content() as AssistantJoinRequest) else {
                return .unsupported
            }
            return .assistantJoinRequest(request)
        }

        if contentType == .readReceipt {
            return .readReceipt
        }

        return .unsupported
    }
}

// MARK: - XMTPiOS encoded-content / content-type bridging

extension MessagingContentType {
    /// Build the Convos-owned content type from the XMTPiOS
    /// `ContentTypeID` (itself a typealias for the generated protobuf
    /// `Xmtp_MessageContents_ContentTypeId`).
    init(_ xmtpContentTypeID: XMTPiOS.ContentTypeID) {
        self.init(
            authorityID: xmtpContentTypeID.authorityID,
            typeID: xmtpContentTypeID.typeID,
            versionMajor: Int(xmtpContentTypeID.versionMajor),
            versionMinor: Int(xmtpContentTypeID.versionMinor)
        )
    }
}

extension MessagingEncodedContent {
    /// Build the Convos-owned encoded content from the XMTPiOS protobuf
    /// value.
    ///
    /// The `compression` field on the protobuf side uses a generated
    /// enum; the mapping here is one-to-one with the XIP-defined cases.
    init(_ xmtpEncodedContent: XMTPiOS.EncodedContent) {
        let compression: MessagingCompression?
        if xmtpEncodedContent.hasCompression {
            switch xmtpEncodedContent.compression {
            case .deflate: compression = .deflate
            case .gzip: compression = .gzip
            case .UNRECOGNIZED: compression = nil
            }
        } else {
            compression = nil
        }

        self.init(
            type: MessagingContentType(xmtpEncodedContent.type),
            parameters: xmtpEncodedContent.parameters,
            content: xmtpEncodedContent.content,
            fallback: xmtpEncodedContent.hasFallback
                ? xmtpEncodedContent.fallback
                : nil,
            compression: compression
        )
    }
}

// MARK: - XIP payload adapters

extension MessagingReplyPayload {
    /// Mirrors prior `handleReplyContent()` decoding: we only care
    /// about `reference`, the inner content type, and the inner
    /// payload (which may itself be text / attachment / remote
    /// attachment).
    init(_ xmtpReply: XMTPiOS.Reply) {
        let innerContentType = MessagingContentType(xmtpReply.contentType)
        let innerPayload: MessagingReplyInnerPayload

        switch innerContentType {
        case .text:
            if let text = xmtpReply.content as? String {
                innerPayload = .text(text)
            } else {
                innerPayload = .other
            }
        case .attachment:
            if let attachment = xmtpReply.content as? XMTPiOS.Attachment {
                innerPayload = .attachment(MessagingAttachmentPayload(attachment))
            } else {
                innerPayload = .other
            }
        case .remoteAttachment:
            if let remoteAttachment = xmtpReply.content as? XMTPiOS.RemoteAttachment {
                innerPayload = .remoteAttachment(
                    MessagingRemoteAttachmentPayload(remoteAttachment)
                )
            } else {
                innerPayload = .other
            }
        default:
            innerPayload = .other
        }

        self.init(
            reference: xmtpReply.reference,
            innerContentType: innerContentType,
            innerPayload: innerPayload
        )
    }
}

extension MessagingAttachmentPayload {
    init(_ xmtpAttachment: XMTPiOS.Attachment) {
        self.init(
            data: xmtpAttachment.data,
            filename: xmtpAttachment.filename,
            mimeType: xmtpAttachment.mimeType
        )
    }
}

extension MessagingRemoteAttachmentPayload {
    init(_ xmtpRemoteAttachment: XMTPiOS.RemoteAttachment) {
        self.init(
            url: xmtpRemoteAttachment.url,
            contentDigest: xmtpRemoteAttachment.contentDigest,
            secret: xmtpRemoteAttachment.secret,
            salt: xmtpRemoteAttachment.salt,
            nonce: xmtpRemoteAttachment.nonce,
            filename: xmtpRemoteAttachment.filename
        )
    }
}

extension MessagingGroupUpdatedPayload {
    init(_ xmtpGroupUpdated: XMTPiOS.GroupUpdated) {
        let metadataFieldChanges: [MetadataFieldChange] = xmtpGroupUpdated
            .metadataFieldChanges
            .map { change in
                MetadataFieldChange(
                    fieldName: change.fieldName,
                    oldValue: change.hasOldValue ? change.oldValue : nil,
                    newValue: change.hasNewValue ? change.newValue : nil
                )
            }

        self.init(
            initiatedByInboxId: xmtpGroupUpdated.initiatedByInboxID,
            addedInboxIds: xmtpGroupUpdated.addedInboxes.map { $0.inboxID },
            removedInboxIds: xmtpGroupUpdated.removedInboxes.map { $0.inboxID },
            metadataFieldChanges: metadataFieldChanges
        )
    }
}

// MARK: - Private

/// `@unchecked Sendable` container for the opaque decoded payload that
/// `XMTPiOS.DecodedMessage.content()` returns. The payload is one of
/// the XIP content-type structs (`Reply`, `Reaction`, `Attachment`,
/// ...), none of which the current libxmtp Swift SDK marks `Sendable`.
/// Since we only ever read the decoded payload on the same thread that
/// produced it (the storage writer's DB-write closure), wrapping it in
/// a single-property struct and opting out of the isolation check is
/// sound. When libxmtp marks its payload types `Sendable`, drop the
/// `@unchecked`.
private struct _MessagingDecodedPayloadBox: @unchecked Sendable {
    let payload: Any
}
