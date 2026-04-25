import ConvosMessagingProtocols
import Foundation
@preconcurrency import XMTPiOS

/// Value-type mappers between the Convos-owned messaging abstraction and
/// `XMTPiOS`.
///
/// Audit §5.2 scope: `MessagingIdentity <-> PublicIdentity`,
/// `MessagingPermission <-> PermissionOption`,
/// `MessagingMemberRole <-> PermissionLevel`,
/// `MessagingInstallation <-> Installation`,
/// `MessagingInbox <-> InboxState`, `MessagingHmacKey(s)`,
/// `MessagingSyncSummary`, `MessagingPermissionPolicySet`,
/// `MessagingMember`.
///
/// `MessagingConsentState`, `MessagingDeliveryStatus`,
/// `MessagingEncodedContent`, `MessagingContentType`, and
/// `MessagingReaction` already live at the storage-boundary layer
/// (`Storage/XMTP DB Representations/`, `Storage/Repositories/DB XMTP
/// Representations/`) from the Stage 1 leaf migrations; those are kept
/// where they are so the DBMessage translator keeps working unchanged.
///
/// Every mapper lives on the abstraction-side type (e.g.
/// `MessagingIdentity.init(_ publicIdentity:)`), matching the convention
/// set by `MessagingDeliveryStatus(_: XMTPiOS.MessageDeliveryStatus)` and
/// `MessagingConsentState(_: XMTPiOS.ConsentState)`.

// MARK: - Identity

public extension MessagingIdentity {
    /// Build a Convos-owned identity from an XMTPiOS public identity.
    init(_ xmtpIdentity: XMTPiOS.PublicIdentity) {
        self.init(
            kind: MessagingIdentityKind(xmtpIdentity.kind),
            identifier: xmtpIdentity.identifier
        )
    }

    /// Project back to `XMTPiOS.PublicIdentity`. Only adapter code
    /// should ever call this.
    var xmtpPublicIdentity: XMTPiOS.PublicIdentity {
        XMTPiOS.PublicIdentity(
            kind: kind.xmtpIdentityKind,
            identifier: identifier
        )
    }
}

public extension MessagingIdentityKind {
    init(_ xmtpIdentityKind: XMTPiOS.IdentityKind) {
        switch xmtpIdentityKind {
        case .ethereum: self = .ethereum
        case .passkey: self = .passkey
        }
    }

    var xmtpIdentityKind: XMTPiOS.IdentityKind {
        switch self {
        case .ethereum: return .ethereum
        case .passkey: return .passkey
        }
    }
}

// MARK: - Installation / inbox state

public extension MessagingInstallation {
    init(_ xmtpInstallation: XMTPiOS.Installation) {
        self.init(id: xmtpInstallation.id, createdAt: xmtpInstallation.createdAt)
    }
}

public extension MessagingInbox {
    init(_ xmtpInboxState: XMTPiOS.InboxState) {
        self.init(
            inboxId: xmtpInboxState.inboxId,
            identities: xmtpInboxState.identities.map(MessagingIdentity.init),
            installations: xmtpInboxState.installations.map(MessagingInstallation.init),
            recoveryIdentity: MessagingIdentity(xmtpInboxState.recoveryIdentity)
        )
    }
}

// MARK: - Permission / role

public extension MessagingPermission {
    init(_ xmtpOption: XMTPiOS.PermissionOption) {
        switch xmtpOption {
        case .allow: self = .allow
        case .deny: self = .deny
        case .admin: self = .admin
        case .superAdmin: self = .superAdmin
        case .unknown: self = .unknown
        }
    }

    var xmtpPermissionOption: XMTPiOS.PermissionOption {
        switch self {
        case .allow: return .allow
        case .deny: return .deny
        case .admin: return .admin
        case .superAdmin: return .superAdmin
        case .unknown: return .unknown
        }
    }
}

public extension MessagingMemberRole {
    init(_ xmtpLevel: XMTPiOS.PermissionLevel) {
        switch xmtpLevel {
        case .Member: self = .member
        case .Admin: self = .admin
        case .SuperAdmin: self = .superAdmin
        }
    }
}

public extension MessagingPermissionPolicySet {
    init(_ xmtpPolicySet: XMTPiOS.PermissionPolicySet) {
        self.init(
            addMemberPolicy: MessagingPermission(xmtpPolicySet.addMemberPolicy),
            removeMemberPolicy: MessagingPermission(xmtpPolicySet.removeMemberPolicy),
            addAdminPolicy: MessagingPermission(xmtpPolicySet.addAdminPolicy),
            removeAdminPolicy: MessagingPermission(xmtpPolicySet.removeAdminPolicy),
            updateGroupNamePolicy: MessagingPermission(xmtpPolicySet.updateGroupNamePolicy),
            updateGroupDescriptionPolicy: MessagingPermission(xmtpPolicySet.updateGroupDescriptionPolicy),
            updateGroupImagePolicy: MessagingPermission(xmtpPolicySet.updateGroupImagePolicy),
            updateMessageDisappearingPolicy: MessagingPermission(xmtpPolicySet.updateMessageDisappearingPolicy),
            updateAppDataPolicy: MessagingPermission(xmtpPolicySet.updateAppDataPolicy)
        )
    }
}

public extension MessagingMember {
    init(_ xmtpMember: XMTPiOS.Member) {
        self.init(
            inboxId: xmtpMember.inboxId,
            identities: xmtpMember.identities.map(MessagingIdentity.init),
            role: MessagingMemberRole(xmtpMember.permissionLevel),
            consentState: MessagingConsentState(xmtpMember.consentState)
        )
    }
}

// MARK: - Sync summary

public extension MessagingSyncSummary {
    init(_ xmtpSummary: XMTPiOS.GroupSyncSummary) {
        self.init(
            numEligible: xmtpSummary.numEligible,
            numSynced: xmtpSummary.numSynced
        )
    }
}

// MARK: - HMAC keys

public extension MessagingHmacKey {
    /// Build from an individual XIP HMAC-key-data protobuf entry.
    init(_ xmtpHmacKeyData: Xmtp_KeystoreApi_V1_GetConversationHmacKeysResponse.HmacKeyData) {
        self.init(
            key: xmtpHmacKeyData.hmacKey,
            thirtyDayPeriodsSinceEpoch: xmtpHmacKeyData.thirtyDayPeriodsSinceEpoch
        )
    }
}

public extension MessagingHmacKeys {
    /// Build from `Conversation.getHmacKeys()` / `Group.getHmacKeys()` /
    /// `Dm.getHmacKeys()`. Each topic on the response maps 1:1 to a
    /// topic on our bag.
    init(_ xmtpHmacResponse: Xmtp_KeystoreApi_V1_GetConversationHmacKeysResponse) {
        var keysByTopic: [String: [MessagingHmacKey]] = [:]
        for (topic, keys) in xmtpHmacResponse.hmacKeys {
            keysByTopic[topic] = keys.values.map(MessagingHmacKey.init)
        }
        self.init(keysByTopic: keysByTopic)
    }
}

// MARK: - Conversation debug info

// `MessagingConversationDebugInfo.init(_ xmtpDebugInfo:)` and
// `MessagingCommitLogForkStatus.init(_ xmtpStatus:)` live in
// `Extensions/Conversation+ExportDebugInfo.swift` from the Stage 1
// leaf migration. No duplicate needed here.

// MARK: - Message metadata

public extension MessagingMessageMetadata {
    /// Build from libxmtp's `MessageMetadata` (typealias for
    /// `FfiMessageMetadata`). The pinned libxmtp Swift SDK's
    /// `FfiMessageMetadata` today only surfaces `cursor` (with
    /// `nodeId`/`sequenceId`) and `createdNs` — there is no sender
    /// identity on the metadata struct. The abstraction's
    /// `senderInboxId` must therefore be supplied by the caller (the
    /// sleeping-inbox checker already knows which inbox asked).
    ///
    /// FIXME(upstream): tighten back to a single-argument init once
    /// libxmtp exposes sender identity on `FfiMessageMetadata`.
    init(_ xmtpMetadata: XMTPiOS.MessageMetadata, senderInboxId: MessagingInboxID) {
        self.init(
            sentAtNs: xmtpMetadata.createdNs,
            senderInboxId: senderInboxId
        )
    }
}

// MARK: - Conversation order / filter

public extension XMTPiOS.ConversationsOrderBy {
    init(_ orderBy: MessagingOrderBy) {
        switch orderBy {
        case .createdAt: self = .createdAt
        case .lastActivity: self = .lastActivity
        }
    }
}

public extension XMTPiOS.ConversationFilterType {
    init(_ filter: MessagingConversationFilter) {
        switch filter {
        case .all: self = .all
        case .groups: self = .groups
        case .dms: self = .dms
        }
    }
}

public extension XMTPiOS.SortDirection {
    init(_ direction: MessagingSortDirection) {
        switch direction {
        case .ascending: self = .ascending
        case .descending: self = .descending
        }
    }
}

// MARK: - Delivery status (back-projection used by message-query filters)

public extension MessagingDeliveryStatus {
    /// Adapter-side projection back onto XMTPiOS for filter queries.
    /// The forward direction lives in the Stage 1 leaf
    /// (`MessageDeliveryStatus+DBRepresentation.swift`).
    var xmtpMessageDeliveryStatus: XMTPiOS.MessageDeliveryStatus {
        switch self {
        case .failed: return .failed
        case .unpublished: return .unpublished
        case .published: return .published
        case .all: return .all
        }
    }
}

// MARK: - Content type projection

public extension MessagingContentType {
    /// Adapter-side projection to XMTPiOS's generated protobuf content
    /// type. Used when round-tripping `MessagingEncodedContent` back
    /// onto the wire for `send` / `prepare`.
    var xmtpContentTypeID: XMTPiOS.ContentTypeID {
        XMTPiOS.ContentTypeID(
            authorityID: authorityID,
            typeID: typeID,
            versionMajor: versionMajor,
            versionMinor: versionMinor
        )
    }
}

public extension MessagingCompression {
    /// Projection onto the XMTPiOS public `EncodedContentCompression`
    /// enum used by `SendOptions.compression`.
    var xmtpCompression: XMTPiOS.EncodedContentCompression {
        switch self {
        case .gzip: return .gzip
        case .deflate: return .deflate
        }
    }

    /// Projection onto the generated protobuf `Xmtp_MessageContents_Compression`
    /// enum used directly on `EncodedContent.compression`.
    var xmtpWireCompression: Xmtp_MessageContents_Compression {
        switch self {
        case .gzip: return .gzip
        case .deflate: return .deflate
        }
    }
}

public extension MessagingEncodedContent {
    /// Adapter-side projection back to `XMTPiOS.EncodedContent` (the
    /// protobuf wire struct). Used on the outbound `prepare` /
    /// `sendOptimistic` path so call sites never construct the
    /// XMTPiOS protobuf directly.
    var xmtpEncodedContent: XMTPiOS.EncodedContent {
        var wire = XMTPiOS.EncodedContent()
        wire.type = type.xmtpContentTypeID
        wire.parameters = parameters
        wire.content = content
        if let fallback {
            wire.fallback = fallback
        }
        if let compression {
            wire.compression = compression.xmtpWireCompression
        }
        return wire
    }
}
