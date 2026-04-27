import ConvosMessagingProtocols
import Foundation

/// Convos-owned mirrors of the XIP-spec standard content types.
///
/// Storage-side dispatch is expressed against `MessagingContentType`
/// values, which the abstraction layer owns. The XIP
/// authority/type/major/minor tuples match the libxmtp constants
/// exactly so `MessagingEncodedContent.type` (built from either the
/// XMTPiOS adapter or a DTU adapter) compares equal to these.
///
/// These constants are declared as `static let` members of
/// `MessagingContentType` (rather than free functions) so call sites
/// read as `MessagingContentType.text` and avoid colliding with the
/// XMTPiOS-level `ContentTypeText`, which still exists because the
/// outgoing-message + custom-codec paths still live in the XMTPiOS
/// layer.
public extension MessagingContentType {
    /// `xmtp.org/text:1.0`
    static let text: MessagingContentType = MessagingContentType(
        authorityID: "xmtp.org",
        typeID: "text",
        versionMajor: 1,
        versionMinor: 0
    )

    /// `xmtp.org/reply:1.0`
    static let reply: MessagingContentType = MessagingContentType(
        authorityID: "xmtp.org",
        typeID: "reply",
        versionMajor: 1,
        versionMinor: 0
    )

    /// `xmtp.org/reaction:1.0`
    static let reaction: MessagingContentType = MessagingContentType(
        authorityID: "xmtp.org",
        typeID: "reaction",
        versionMajor: 1,
        versionMinor: 0
    )

    /// `xmtp.org/reaction:2.0`
    static let reactionV2: MessagingContentType = MessagingContentType(
        authorityID: "xmtp.org",
        typeID: "reaction",
        versionMajor: 2,
        versionMinor: 0
    )

    /// `xmtp.org/attachment:1.0`
    static let attachment: MessagingContentType = MessagingContentType(
        authorityID: "xmtp.org",
        typeID: "attachment",
        versionMajor: 1,
        versionMinor: 0
    )

    /// `xmtp.org/remoteStaticAttachment:1.0`
    static let remoteAttachment: MessagingContentType = MessagingContentType(
        authorityID: "xmtp.org",
        typeID: "remoteStaticAttachment",
        versionMajor: 1,
        versionMinor: 0
    )

    /// `xmtp.org/multiRemoteStaticAttachment:1.0`
    static let multiRemoteAttachment: MessagingContentType = MessagingContentType(
        authorityID: "xmtp.org",
        typeID: "multiRemoteStaticAttachment",
        versionMajor: 1,
        versionMinor: 0
    )

    /// `xmtp.org/group_updated:1.0`
    static let groupUpdated: MessagingContentType = MessagingContentType(
        authorityID: "xmtp.org",
        typeID: "group_updated",
        versionMajor: 1,
        versionMinor: 0
    )

    /// `xmtp.org/readReceipt:1.0`
    static let readReceipt: MessagingContentType = MessagingContentType(
        authorityID: "xmtp.org",
        typeID: "readReceipt",
        versionMajor: 1,
        versionMinor: 0
    )

    /// `convos.org/explode_settings:1.0`
    static let explodeSettings: MessagingContentType = MessagingContentType(
        authorityID: "convos.org",
        typeID: "explode_settings",
        versionMajor: 1,
        versionMinor: 0
    )

    /// `convos.org/assistant_join_request:1.0`
    static let assistantJoinRequest: MessagingContentType = MessagingContentType(
        authorityID: "convos.org",
        typeID: "assistant_join_request",
        versionMajor: 1,
        versionMinor: 0
    )

    /// `convos.org/connection_grant_request:1.0`
    static let connectionGrantRequest: MessagingContentType = MessagingContentType(
        authorityID: "convos.org",
        typeID: "connection_grant_request",
        versionMajor: 1,
        versionMinor: 0
    )

    /// `convos.org/typing_indicator:1.0`
    ///
    /// Mirror of `Custom Content Types/TypingIndicatorCodec.swift`'s
    /// `ContentTypeTypingIndicator` so writers can dispatch on the
    /// abstraction-layer type rather than the XMTPiOS-owned constant.
    static let typingIndicator: MessagingContentType = MessagingContentType(
        authorityID: "convos.org",
        typeID: "typing_indicator",
        versionMajor: 1,
        versionMinor: 0
    )

    /// `convos.org/profile_update:1.0`
    ///
    /// Mirror of `ConvosProfiles.ContentTypeProfileUpdate` so writers
    /// can dispatch on the abstraction-layer type.
    static let profileUpdate: MessagingContentType = MessagingContentType(
        authorityID: "convos.org",
        typeID: "profile_update",
        versionMajor: 1,
        versionMinor: 0
    )

    /// `convos.org/profile_snapshot:1.0`
    ///
    /// Mirror of `ConvosProfiles.ContentTypeProfileSnapshot` so
    /// writers can dispatch on the abstraction-layer type.
    static let profileSnapshot: MessagingContentType = MessagingContentType(
        authorityID: "convos.org",
        typeID: "profile_snapshot",
        versionMajor: 1,
        versionMinor: 0
    )
}

// MARK: - MessagingMessage convenience predicates

/// Profile / typing-indicator / read-receipt predicates on
/// `MessagingMessage`. Kept beside the content-type constants so the
/// authority/type-ID lookup is obvious.
public extension MessagingMessage {
    /// True when the message carries a `ProfileUpdate` or
    /// `ProfileSnapshot` XIP payload. Used by sync / storage to skip
    /// writing profile messages as ordinary `DBMessage` rows.
    var isProfileMessage: Bool {
        encodedContent.type == .profileUpdate
            || encodedContent.type == .profileSnapshot
    }

    /// True when the message is a Convos typing-indicator ping.
    /// Matches by authority + type ID only — the codec doesn't care
    /// about version.
    var isTypingIndicator: Bool {
        let type = encodedContent.type
        return type.authorityID == MessagingContentType.typingIndicator.authorityID
            && type.typeID == MessagingContentType.typingIndicator.typeID
    }

    /// True when the message is a read-receipt. Matches by authority +
    /// type ID only.
    var isReadReceipt: Bool {
        let type = encodedContent.type
        return type.authorityID == MessagingContentType.readReceipt.authorityID
            && type.typeID == MessagingContentType.readReceipt.typeID
    }
}
