import Foundation

// MARK: - Delivery status

/// First-class delivery state for every `MessagingMessage`.
///
/// Constraint per audit §3: `MessagingDeliveryStatus` is required on
/// every message the UI sees (today mapped to `DBMessage.status` via
/// `MessageDeliveryStatus+DBRepresentation.swift:5-14`). Preserving
/// `.failed` and `.all` matches the libxmtp surface so the existing
/// mapping can be swapped over in Stage 2/3 without a new case.
public enum MessagingDeliveryStatus: String, Hashable, Sendable, Codable {
    case unpublished
    case published
    case failed
    case all
}

// MARK: - Prepared message

/// Handle returned from `prepare(...)` / `sendOptimistic(...)`.
///
/// Maps 1:1 to libxmtp's `prepareMessage` hex-id → `publishMessage(messageId:)`
/// flow. The audit constraint keeps `prepare`, `sendOptimistic`, and
/// `publish` as three distinct operations; this handle is how call
/// sites thread the prepared state through.
public struct MessagingPreparedMessage: Hashable, Sendable {
    /// Hex id exactly as libxmtp returns. Treat as opaque.
    public let messageId: String
    public let conversationId: String
    public let deliveryStatus: MessagingDeliveryStatus

    public init(
        messageId: String,
        conversationId: String,
        deliveryStatus: MessagingDeliveryStatus
    ) {
        self.messageId = messageId
        self.conversationId = conversationId
        self.deliveryStatus = deliveryStatus
    }
}

// MARK: - Message metadata

/// Result of the static `newestMessageMetadata` sleeping-inbox check.
///
/// Replaces the libxmtp `MessageMetadata` typealias so nothing above
/// the adapter sees `FfiMessageMetadata`.
public struct MessagingMessageMetadata: Hashable, Sendable {
    public let sentAtNs: Int64
    public let senderInboxId: MessagingInboxID

    public init(sentAtNs: Int64, senderInboxId: MessagingInboxID) {
        self.sentAtNs = sentAtNs
        self.senderInboxId = senderInboxId
    }
}

// MARK: - Message query

/// Sort direction for message lookups.
public enum MessagingSortDirection: String, Hashable, Sendable, Codable {
    case ascending
    case descending
}

/// Query options for `MessagingConversationCore.messages(query:)`.
///
/// Matches the libxmtp time-based query shape (`beforeNs`, `afterNs`)
/// rather than introducing opaque cursor tokens (see audit §4
/// "Pass through opaque").
public struct MessagingMessageQuery: Hashable, Sendable {
    public var limit: Int?
    public var beforeNs: Int64?
    public var afterNs: Int64?
    public var direction: MessagingSortDirection
    public var deliveryStatus: MessagingDeliveryStatus
    public var excludeContentTypes: [MessagingContentType]?
    public var excludeSenderInboxIds: [MessagingInboxID]?

    public init(
        limit: Int? = nil,
        beforeNs: Int64? = nil,
        afterNs: Int64? = nil,
        direction: MessagingSortDirection = .descending,
        deliveryStatus: MessagingDeliveryStatus = .all,
        excludeContentTypes: [MessagingContentType]? = nil,
        excludeSenderInboxIds: [MessagingInboxID]? = nil
    ) {
        self.limit = limit
        self.beforeNs = beforeNs
        self.afterNs = afterNs
        self.direction = direction
        self.deliveryStatus = deliveryStatus
        self.excludeContentTypes = excludeContentTypes
        self.excludeSenderInboxIds = excludeSenderInboxIds
    }
}

// MARK: - Message

/// The Convos-owned value type that replaces `XMTPiOS.DecodedMessage`.
///
/// Every field the current `DecodedMessage+DBRepresentation.swift`
/// translator reads is preserved, with one tightening per audit §3:
///
/// * `deliveryStatus` is a first-class `MessagingDeliveryStatus`
///   value (no optionals, no `unknown`).
///
/// `senderInstallationId` is currently **optional** and expected to be
/// populated only when the underlying SDK surfaces it. The libxmtp FFI
/// layer (`FfiMessage`) exposes the field, but the pinned Swift SDK at
/// `ios-4.9.0-dev.88ddfad` does not surface it on
/// `XMTPiOS.DecodedMessage` (see `sdks/ios/Sources/XMTPiOS/Libxmtp/DecodedMessage.swift`;
/// only `senderInboxId` is exposed). Per the hard project rule libxmtp
/// is read-only and cannot be patched downstream, so the abstraction
/// field is optional until upstream lands the accessor. Once exposed,
/// tighten this back to non-optional `MessagingInstallationID` —
/// the multi-installation constraint in audit §3 requires the field on
/// every `MessagingMessage` — and update the XMTPiOS adapter to read
/// `FfiMessage.senderInstallationId` directly. Tracks audit open
/// question #1.
public struct MessagingMessage: Sendable, Identifiable {
    public let id: String
    public let conversationId: String
    public let senderInboxId: MessagingInboxID
    /// See type doc comment: optional until upstream XMTPiOS exposes
    /// `senderInstallationId` on `DecodedMessage`. Tighten to
    /// non-optional when the libxmtp Swift SDK bumps.
    public let senderInstallationId: MessagingInstallationID?
    public let sentAt: Date
    public let sentAtNs: Int64
    public let insertedAt: Date
    public let insertedAtNs: Int64
    public let expiresAtNs: Int64?
    public let deliveryStatus: MessagingDeliveryStatus
    public let encodedContent: MessagingEncodedContent

    /// Optional eagerly-loaded reactions / enriched-message children
    /// (matches the current `DecodedMessage` surface Convos consumes).
    public var childMessages: [MessagingMessage]?

    /// Decoder indirection. Callers supply the expected native payload
    /// type; the implementation uses `MessagingCodecRegistry` (or an
    /// adapter-provided resolver) to decode `encodedContent`.
    ///
    /// Stage 1 ships the protocol shape; the concrete adapter wires
    /// this to the codec registry in Stage 2.
    public let contentDecoder: @Sendable (MessagingEncodedContent) throws -> Any

    public init(
        id: String,
        conversationId: String,
        senderInboxId: MessagingInboxID,
        senderInstallationId: MessagingInstallationID?,
        sentAt: Date,
        sentAtNs: Int64,
        insertedAt: Date,
        insertedAtNs: Int64,
        expiresAtNs: Int64?,
        deliveryStatus: MessagingDeliveryStatus,
        encodedContent: MessagingEncodedContent,
        childMessages: [MessagingMessage]? = nil,
        contentDecoder: @escaping @Sendable (MessagingEncodedContent) throws -> Any
    ) {
        self.id = id
        self.conversationId = conversationId
        self.senderInboxId = senderInboxId
        self.senderInstallationId = senderInstallationId
        self.sentAt = sentAt
        self.sentAtNs = sentAtNs
        self.insertedAt = insertedAt
        self.insertedAtNs = insertedAtNs
        self.expiresAtNs = expiresAtNs
        self.deliveryStatus = deliveryStatus
        self.encodedContent = encodedContent
        self.childMessages = childMessages
        self.contentDecoder = contentDecoder
    }

    /// Decodes the encoded content as `T`. Wraps the underlying
    /// adapter's `decode` call; throws if the payload does not match
    /// the requested type.
    public func content<T>() throws -> T {
        let decoded: Any = try contentDecoder(encodedContent)
        guard let typed = decoded as? T else {
            throw MessagingMessageError.contentTypeMismatch(
                expected: String(describing: T.self),
                actual: String(describing: Swift.type(of: decoded))
            )
        }
        return typed
    }
}

// MARK: - Errors

public enum MessagingMessageError: Error, Sendable {
    case contentTypeMismatch(expected: String, actual: String)
}
