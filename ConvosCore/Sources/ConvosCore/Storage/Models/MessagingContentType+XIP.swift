import Foundation

/// Convos-owned mirrors of the XIP-spec standard content types.
///
/// Stage 3 migration (audit §5): the prior dispatch in
/// `Storage/XMTP DB Representations/DecodedMessage+DBRepresentation.swift`
/// compared `encodedContent.type` against XMTPiOS's top-level
/// `ContentTypeText` / `ContentTypeReply` / ... constants. After this
/// migration the dispatch is expressed against `MessagingContentType`
/// values, which the abstraction layer owns. The XIP authority/type/
/// major/minor tuples are preserved exactly so
/// `MessagingEncodedContent.type` (built from either the XMTPiOS
/// adapter or a future DTU adapter) compares equal to these constants.
///
/// These constants are intentionally declared as `static let` members
/// of `MessagingContentType` rather than free functions so that call
/// sites reading one of these read as `MessagingContentType.text`
/// rather than `ContentTypeText` and avoid colliding with the
/// XMTPiOS-level `ContentTypeText` (which still exists for now because
/// `Custom Content Types/*Codec.swift` and the outgoing-message path
/// in `OutgoingMessageWriter.swift` have not yet migrated — that is a
/// later Stage 3/4 scope).
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
}
