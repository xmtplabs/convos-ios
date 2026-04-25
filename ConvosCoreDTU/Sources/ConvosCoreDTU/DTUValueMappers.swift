import ConvosCore
import ConvosMessagingProtocols
import Foundation
import XMTPDTU

/// Value-type mappers between the Convos-owned messaging abstraction and
/// the XMTPDTU Swift SDK types.
///
/// Mirrors the `XMTPiOSValueMappers.swift` convention in the XMTPiOS
/// adapter: every mapper lives on the abstraction-side type, typed as
/// `init(_ dtuValue:)` / `var dtuXxx:` for bidirectional projection.
///
/// DTU's engine surfaces a narrower type set than XMTPiOS — values like
/// HMAC keys, push topics, device-sync archives don't exist in the engine
/// at all. This file only models the projections that do have a 1:1
/// correspondence (consent, content, delivery status, etc.); the
/// unmodeled ones are handled by throwing `DTUMessagingNotSupportedError`
/// at the protocol-method boundary.

// MARK: - Consent

public extension MessagingConsentState {
    init(_ dtu: XMTPDTU.ConsentState) {
        switch dtu {
        case .allowed: self = .allowed
        case .denied: self = .denied
        case .unknown: self = .unknown
        }
    }

    var dtuConsentState: XMTPDTU.ConsentState {
        switch self {
        case .allowed: return .allowed
        case .denied: return .denied
        case .unknown: return .unknown
        }
    }
}

// MARK: - Delivery status

public extension MessagingDeliveryStatus {
    /// DTU surfaces only `.unpublished` / `.published` on the wire —
    /// `failed` + `all` are XMTPiOS-specific. Forward direction maps
    /// the two real cases; the other two are adapter-side synthetic.
    init(_ dtu: XMTPDTU.DeliveryStatus) {
        switch dtu {
        case .unpublished: self = .unpublished
        case .published: self = .published
        }
    }
}

// MARK: - Content type

public extension MessagingContentType {
    init(_ dtu: XMTPDTU.ContentTypeId) {
        self.init(
            authorityID: dtu.authorityId,
            typeID: dtu.typeId,
            versionMajor: Int(dtu.versionMajor),
            versionMinor: Int(dtu.versionMinor)
        )
    }

    var dtuContentTypeId: XMTPDTU.ContentTypeId {
        XMTPDTU.ContentTypeId(
            authorityId: authorityID,
            typeId: typeID,
            versionMajor: UInt32(versionMajor),
            versionMinor: UInt32(versionMinor)
        )
    }
}

// MARK: - Permission policy

public extension MessagingPermission {
    init(_ dtu: XMTPDTU.PermissionPolicy) {
        switch dtu {
        case .allow: self = .allow
        case .deny: self = .deny
        case .admin: self = .admin
        case .superAdmin: self = .superAdmin
        case .doesNotExist, .other: self = .unknown
        }
    }
}

public extension MessagingPermissionPolicySet {
    init(_ dtu: XMTPDTU.GroupPermissionPolicySet) {
        self.init(
            addMemberPolicy: MessagingPermission(dtu.addMemberPolicy),
            removeMemberPolicy: MessagingPermission(dtu.removeMemberPolicy),
            addAdminPolicy: MessagingPermission(dtu.addAdminPolicy),
            removeAdminPolicy: MessagingPermission(dtu.removeAdminPolicy),
            updateGroupNamePolicy: MessagingPermission(dtu.updateGroupNamePolicy),
            updateGroupDescriptionPolicy: MessagingPermission(dtu.updateGroupDescriptionPolicy),
            updateGroupImagePolicy: MessagingPermission(dtu.updateGroupImageUrlSquarePolicy),
            updateMessageDisappearingPolicy: MessagingPermission(dtu.updateMessageDisappearingPolicy),
            updateAppDataPolicy: MessagingPermission(dtu.updateAppDataPolicy)
        )
    }
}

// MARK: - Installation state

public extension MessagingInstallation {
    /// Build from DTU's `InboxStateInstallation`. DTU's installation
    /// record is intentionally slim — no `createdAt`, just the id + active/
    /// revoked state. The abstraction's `createdAt` is optional for
    /// exactly this reason; we leave it nil when the DTU side doesn't
    /// surface it.
    init(_ dtu: DTUUniverse.InboxStateInstallation) {
        self.init(id: dtu.id, createdAt: nil)
    }
}

// MARK: - Encoded content

public extension MessagingEncodedContent {
    /// Build a `MessagingEncodedContent` from a DTU `NormalizedMessage`.
    /// Text content round-trips as a UTF-8 body under the `xmtp.org/text`
    /// content type. Binary content preserves the native content-type
    /// tag + parameters + base64 payload.
    init(_ dtu: XMTPDTU.NormalizedMessage) {
        let messagingType = MessagingContentType(dtu.contentType)
        switch dtu.content {
        case .text(let text):
            let data = text.data(using: .utf8) ?? Data()
            self.init(
                type: messagingType,
                parameters: [:],
                content: data,
                fallback: nil,
                compression: nil
            )
        case .binary(let payload):
            let binaryType = MessagingContentType(payload.contentTypeId)
            let data = Data(base64Encoded: payload.base64) ?? Data()
            self.init(
                type: binaryType,
                parameters: payload.parameters,
                content: data,
                fallback: payload.fallback,
                compression: nil
            )
        }
    }
}

// MARK: - Message

public extension MessagingMessage {
    /// Build a `MessagingMessage` from a DTU `NormalizedMessage`.
    ///
    /// DTU's engine surfaces fewer fields than XMTPiOS's `DecodedMessage`:
    ///  - `senderInstallationId` is optional on both sides; DTU uses its
    ///    sender alias (e.g. `alice-phone`) verbatim.
    ///  - `insertedAt` / `sentAt` are not surfaced on the wire today
    ///    (DTU's engine is deterministic and the test harness controls
    ///    time). We synthesize them to `Date()` at decode time; callers
    ///    relying on real timestamps for ordering should use `sequence`.
    ///  - `expiresAtNs` is always nil: DTU doesn't model disappearing
    ///    messages yet.
    ///
    /// The `contentDecoder` is a synchronous closure per the
    /// abstraction's protocol; the shared `MessagingCodecRegistry` is
    /// actor-isolated (`await`), so we can't reach it from this
    /// closure. We take the same fast-path the XMTPiOS storage
    /// translator takes for text content and return the raw bytes for
    /// anything else. A Stage 6+ codec-registry rewrite would remove
    /// this split (see audit §5 Stage 6).
    init(
        _ dtu: XMTPDTU.NormalizedMessage,
        conversationId: String,
        referenceDate: Date = Date()
    ) {
        let encoded = MessagingEncodedContent(dtu)
        let syncDecoder: @Sendable (MessagingEncodedContent) throws -> Any = { content in
            let type = content.type
            if type.authorityID == "xmtp.org", type.typeID == "text" {
                return String(data: content.content, encoding: .utf8) ?? ""
            }
            return content.content
        }

        let sentAtNs: Int64 = Int64(dtu.sequence)
        self.init(
            id: dtu.id,
            conversationId: conversationId,
            senderInboxId: dtu.sender,
            senderInstallationId: dtu.sender,
            sentAt: referenceDate,
            sentAtNs: sentAtNs,
            insertedAt: referenceDate,
            insertedAtNs: sentAtNs,
            expiresAtNs: nil,
            deliveryStatus: MessagingDeliveryStatus(dtu.deliveryStatus),
            encodedContent: encoded,
            childMessages: nil,
            contentDecoder: syncDecoder
        )
    }
}

// MARK: - Text content helper

/// Turn a `MessagingEncodedContent` whose type is `xmtp.org/text` back into
/// a plain UTF-8 string. The DTU adapter's send / prepare flows rely on
/// this to unpack the caller's encoded content into a `ContentPayload.text`
/// wire value — DTU's engine only supports authored text today.
enum DTUEncodedContentUnpacker {
    static func asText(_ content: MessagingEncodedContent) throws -> String {
        guard
            content.type.authorityID == "xmtp.org",
            content.type.typeID == "text"
        else {
            throw DTUMessagingNotSupportedError(
                method: "send/prepare",
                reason: "DTU engine only supports xmtp.org/text content authoring "
                    + "(got \(content.type.authorityID)/\(content.type.typeID))"
            )
        }
        guard let text = String(data: content.content, encoding: .utf8) else {
            throw DTUMessagingNotSupportedError(
                method: "send/prepare",
                reason: "xmtp.org/text payload was not valid UTF-8"
            )
        }
        return text
    }
}
