import ConvosMessagingProtocols
import ConvosProfiles
import Foundation
@preconcurrency import XMTPiOS

// Thin boundary between XMTPiOS SDK types and Convos-owned values
// for storage writers — XMTPiOS-specific helpers concentrated here so
// the writers themselves do not import XMTPiOS.

// MARK: - Member role / consent mapping

fileprivate extension XMTPiOS.PermissionLevel {
    var role: MemberRole {
        switch self {
        case .SuperAdmin: return .superAdmin
        case .Admin: return .admin
        case .Member: return .member
        }
    }
}

fileprivate extension XMTPiOS.ConsentState {
    var memberConsent: Consent {
        switch self {
        case .allowed: return .allowed
        case .denied: return .denied
        case .unknown: return .unknown
        }
    }
}

extension XMTPiOS.Member {
    func dbRepresentation(conversationId: String) -> DBConversationMember {
        .init(conversationId: conversationId,
              inboxId: inboxId,
              role: permissionLevel.role,
              consent: consentState.memberConsent,
              createdAt: Date(),
              invitedByInboxId: nil)
    }
}

// MARK: - MessagingMember → DBConversationMember

/// `[MessagingMember]` -> `[DBConversationMember]` translator. Sits
/// beside the `XMTPiOS.Member` bridge so the two translators are
/// adjacent.
extension MessagingMember {
    func dbRepresentation(conversationId: String) -> DBConversationMember {
        .init(
            conversationId: conversationId,
            inboxId: inboxId,
            role: role.dbMemberRole,
            consent: consentState.consent,
            createdAt: Date(),
            invitedByInboxId: nil
        )
    }
}

fileprivate extension MessagingMemberRole {
    var dbMemberRole: MemberRole {
        switch self {
        case .member: return .member
        case .admin: return .admin
        case .superAdmin: return .superAdmin
        }
    }
}

// MARK: - XMTPiOS.Conversation / XMTPiOS.ConsentState helpers

enum ConversationInviteTagError: Error {
    case attemptedFetchingInviteTagForDM
}

public extension XMTPiOS.Conversation {
    var creatorInboxId: String {
        get async throws {
            switch self {
            case .group(let group):
                return try await group.creatorInboxId()
            case .dm(let dm):
                return try await dm.creatorInboxId()
            }
        }
    }

    var inviteTag: String {
        get async throws {
            switch self {
            case .group(let group):
                return try await XMTPiOSMessagingGroup(xmtpGroup: group).inviteTag()
            case .dm:
                throw ConversationInviteTagError.attemptedFetchingInviteTagForDM
            }
        }
    }
}

extension XMTPiOS.ConsentState {
    var consent: Consent {
        switch self {
        case .allowed: return .allowed
        case .denied: return .denied
        case .unknown: return .unknown
        }
    }
}

// MARK: - XMTPiOS.ConversationDebugInfo → ConversationDebugInfo

extension XMTPiOS.ConversationDebugInfo {
    func toDBDebugInfo() -> ConversationDebugInfo {
        ConversationDebugInfo(
            epoch: epoch,
            maybeForked: maybeForked,
            forkDetails: forkDetails,
            localCommitLog: localCommitLog,
            remoteCommitLog: remoteCommitLog,
            commitLogForkStatus: commitLogForkStatus.toDBStatus()
        )
    }
}

extension XMTPiOS.CommitLogForkStatus {
    func toDBStatus() -> CommitLogForkStatus {
        switch self {
        case .forked: return .forked
        case .notForked: return .notForked
        case .unknown: return .unknown
        }
    }
}

// MARK: - MessagingConversationDebugInfo → ConversationDebugInfo

/// `MessagingConversationDebugInfo` -> `ConversationDebugInfo`
/// translator. Same mapping as the XMTPiOS counterpart above.
extension MessagingConversationDebugInfo {
    func toDBDebugInfo() -> ConversationDebugInfo {
        ConversationDebugInfo(
            epoch: epoch,
            maybeForked: maybeForked,
            forkDetails: forkDetails,
            localCommitLog: localCommitLog,
            remoteCommitLog: remoteCommitLog,
            commitLogForkStatus: commitLogForkStatus.dbCommitLogForkStatus
        )
    }
}

fileprivate extension MessagingCommitLogForkStatus {
    var dbCommitLogForkStatus: CommitLogForkStatus {
        switch self {
        case .forked: return .forked
        case .notForked: return .notForked
        case .unknown: return .unknown
        }
    }
}

// MARK: - XMTPiOS-only writer bridges

/// Helpers for storage writers that need to invoke an XMTPiOS-specific
/// operation on a `MessagingConversation` until the corresponding
/// `Messaging*` surface lands. Each helper downcasts to the XMTPiOS
/// adapter and throws a clear error on any other backend.
enum MessagingWriterBridge {
    /// Send a read-receipt on a `MessagingConversation`.
    // FIXME: see docs/outstanding-messaging-abstraction-work.md#codec-migration
    static func sendReadReceipt(
        conversation: MessagingConversation
    ) async throws {
        guard let xmtpConversation = conversation.underlyingXMTPiOSConversation else {
            throw MessagingWriterBridgeError.notSupportedOnBackend(
                operation: "sendReadReceipt"
            )
        }
        nonisolated(unsafe) let unsafeConversation = xmtpConversation
        try await unsafeConversation.sendReadReceipt()
    }

    /// Send a text reply on a `MessagingConversation`.
    // FIXME: see docs/outstanding-messaging-abstraction-work.md#codec-migration
    @discardableResult
    static func sendTextReply(
        conversation: MessagingConversation,
        replyText: String,
        parentMessageId: String
    ) async throws -> String {
        guard let xmtpConversation = conversation.underlyingXMTPiOSConversation else {
            throw MessagingWriterBridgeError.notSupportedOnBackend(
                operation: "sendTextReply"
            )
        }
        let reply = XMTPiOS.Reply(
            reference: parentMessageId,
            content: replyText,
            contentType: XMTPiOS.ContentTypeText
        )
        nonisolated(unsafe) let unsafeConversation = xmtpConversation
        return try await unsafeConversation.prepareMessage(
            content: reply,
            options: .init(contentType: XMTPiOS.ContentTypeReply)
        )
    }

    /// Publish any previously-prepared messages on a
    /// `MessagingConversation`. Thin wrapper over
    /// `MessagingConversationCore.publish()` that keeps the call site
    /// lexically symmetrical with `sendTextReply` (which must go
    /// through the bridge). Writers can swap back to
    /// `conversation.core.publish()` freely once all reply flows live
    /// on the abstraction.
    static func publishPreparedMessages(
        conversation: MessagingConversation
    ) async throws {
        try await conversation.core.publish()
    }

    /// Reaction action values accepted by the bridge. Mirrors
    /// `XMTPiOS.ReactionAction`.
    enum ReactionActionBridge {
        case added
        case removed

        fileprivate var xmtpAction: XMTPiOS.ReactionAction {
            switch self {
            case .added: return .added
            case .removed: return .removed
            }
        }
    }

    /// Send a reaction on a `MessagingConversation`.
    // FIXME: see docs/outstanding-messaging-abstraction-work.md#codec-migration
    static func sendReaction(
        conversation: MessagingConversation,
        reference: String,
        action: ReactionActionBridge,
        emoji: String,
        referenceInboxId: String,
        shouldPush: Bool
    ) async throws {
        guard let xmtpConversation = conversation.underlyingXMTPiOSConversation else {
            throw MessagingWriterBridgeError.notSupportedOnBackend(
                operation: "sendReaction"
            )
        }
        let reaction = XMTPiOS.Reaction(
            reference: reference,
            action: action.xmtpAction,
            content: emoji,
            schema: .unicode,
            referenceInboxId: referenceInboxId
        )
        let encodedContent = try XMTPiOS.ReactionV2Codec().encode(content: reaction)
        nonisolated(unsafe) let unsafeConversation = xmtpConversation
        try await unsafeConversation.send(
            encodedContent: encodedContent,
            visibilityOptions: XMTPiOS.MessageVisibilityOptions(shouldPush: shouldPush)
        )
    }

    /// Send an `ExplodeSettings` message on a `MessagingConversation`.
    // FIXME: see docs/outstanding-messaging-abstraction-work.md#codec-migration
    static func sendExplode(
        conversation: MessagingConversation,
        expiresAt: Date
    ) async throws {
        guard let xmtpConversation = conversation.underlyingXMTPiOSConversation else {
            throw MessagingWriterBridgeError.notSupportedOnBackend(
                operation: "sendExplode"
            )
        }
        nonisolated(unsafe) let unsafeConversation = xmtpConversation
        try await unsafeConversation.sendExplode(expiresAt: expiresAt)
    }

    // MARK: - Outgoing attachment / reply send bridges
    //
    // FIXME: see docs/outstanding-messaging-abstraction-work.md#codec-migration

    /// Foundation-only projection of
    /// `XMTPiOS.EncryptedEncodedContent`. Mirrors the subset of fields
    /// callers read (payload + digest + secret + salt + nonce).
    struct EncryptedRemoteAttachment: Sendable {
        let payload: Data
        let digest: String
        let secret: Data
        let salt: Data
        let nonce: Data
    }

    /// Encode an in-memory attachment into an encrypted remote
    /// attachment envelope suitable for upload. Mirrors
    /// `RemoteAttachment.encodeEncrypted(content: Attachment(...), codec: AttachmentCodec())`.
    static func encodeEncryptedAttachment(
        filename: String,
        mimeType: String,
        data: Data
    ) throws -> EncryptedRemoteAttachment {
        let attachment = XMTPiOS.Attachment(
            filename: filename,
            mimeType: mimeType,
            data: data
        )
        let encrypted = try XMTPiOS.RemoteAttachment.encodeEncrypted(
            content: attachment,
            codec: XMTPiOS.AttachmentCodec()
        )
        return EncryptedRemoteAttachment(
            payload: encrypted.payload,
            digest: encrypted.digest,
            secret: encrypted.secret,
            salt: encrypted.salt,
            nonce: encrypted.nonce
        )
    }

    /// Prepare an outgoing plain-text message for a
    /// `MessagingConversation`. Downcasts to the XMTPiOS adapter so the
    /// XIP `prepareMessage(content: String)` call stays SDK-side; throws
    /// on non-XMTPiOS backends. Returns the opaque prepared message id.
    // FIXME: see docs/outstanding-messaging-abstraction-work.md#codec-migration
    static func prepareText(
        conversation: MessagingConversation,
        text: String
    ) async throws -> String {
        guard let xmtpConversation = conversation.underlyingXMTPiOSConversation else {
            throw MessagingWriterBridgeError.notSupportedOnBackend(
                operation: "prepareText"
            )
        }
        nonisolated(unsafe) let unsafeConversation = xmtpConversation
        return try await unsafeConversation.prepare(text: text)
    }

    /// Prepare an outgoing remote-attachment message (optionally a
    /// reply) for a `MessagingConversation`. Downcasts to the XMTPiOS
    /// adapter so the XIP codec construction stays SDK-side; throws
    /// on non-XMTPiOS backends. Returns the opaque prepared message id.
    static func prepareRemoteAttachment(
        conversation: MessagingConversation,
        stored: StoredRemoteAttachment,
        replyParentDbId: String?
    ) async throws -> String {
        guard let xmtpConversation = conversation.underlyingXMTPiOSConversation else {
            throw MessagingWriterBridgeError.notSupportedOnBackend(
                operation: "prepareRemoteAttachment"
            )
        }
        let remoteAttachment = try XMTPiOS.RemoteAttachment(
            url: stored.url,
            contentDigest: stored.contentDigest,
            secret: stored.secret,
            salt: stored.salt,
            nonce: stored.nonce,
            scheme: .https,
            contentLength: nil,
            filename: stored.filename
        )
        nonisolated(unsafe) let unsafeConversation = xmtpConversation
        if let replyParentDbId {
            let reply = XMTPiOS.Reply(
                reference: replyParentDbId,
                content: remoteAttachment,
                contentType: XMTPiOS.ContentTypeRemoteAttachment
            )
            return try await unsafeConversation.prepare(reply: reply)
        }
        return try await unsafeConversation.prepare(remoteAttachment: remoteAttachment)
    }

    /// Prepare an outgoing text reply for a `MessagingConversation`.
    /// Downcasts to the XMTPiOS adapter; throws on non-XMTPiOS backends.
    static func prepareTextReply(
        conversation: MessagingConversation,
        text: String,
        replyParentDbId: String
    ) async throws -> String {
        guard let xmtpConversation = conversation.underlyingXMTPiOSConversation else {
            throw MessagingWriterBridgeError.notSupportedOnBackend(
                operation: "prepareTextReply"
            )
        }
        let reply = XMTPiOS.Reply(
            reference: replyParentDbId,
            content: text,
            contentType: XMTPiOS.ContentTypeText
        )
        nonisolated(unsafe) let unsafeConversation = xmtpConversation
        return try await unsafeConversation.prepare(reply: reply)
    }
}

enum MessagingWriterBridgeError: Error, LocalizedError {
    case notSupportedOnBackend(operation: String)

    var errorDescription: String? {
        switch self {
        case .notSupportedOnBackend(let op):
            return "\(op) is not supported on the active messaging backend."
        }
    }
}

// MARK: - ProfileSnapshotBridge

/// Bridges `ConvosProfiles.ProfileSnapshotBuilder.sendSnapshot(group:
/// memberInboxIds:)` — which still takes a raw `XMTPiOS.Group` — onto
/// the `any MessagingGroup` surface that storage writers consume.
// FIXME: see docs/outstanding-messaging-abstraction-work.md#codec-migration
enum ProfileSnapshotBridge {
    static func sendSnapshot(
        group: any MessagingGroup,
        memberInboxIds: [MessagingInboxID]
    ) async throws {
        guard let xmtpiosGroup = (group as? XMTPiOSMessagingGroup)?.underlyingXMTPiOSGroup else {
            throw MessagingWriterBridgeError.notSupportedOnBackend(
                operation: "ProfileSnapshotBuilder.sendSnapshot"
            )
        }
        try await ProfileSnapshotBuilder.sendSnapshot(
            group: xmtpiosGroup,
            memberInboxIds: memberInboxIds
        )
    }

    /// Encodes + sends a `ProfileUpdate` through the XMTPiOS codec
    /// pipeline on behalf of a `MessagingGroup` writer.
    // FIXME: see docs/outstanding-messaging-abstraction-work.md#codec-migration
    static func sendProfileUpdate(
        _ update: ProfileUpdate,
        on group: any MessagingGroup
    ) async throws {
        guard let xmtpiosGroup = (group as? XMTPiOSMessagingGroup)?.underlyingXMTPiOSGroup else {
            throw MessagingWriterBridgeError.notSupportedOnBackend(
                operation: "ProfileUpdateCodec.send"
            )
        }
        let codec = ProfileUpdateCodec()
        let encoded = try codec.encode(content: update)
        _ = try await xmtpiosGroup.send(encodedContent: encoded)
    }
}

// OutgoingMessageWriter shim. See the per-op FIXMEs at the bridge
// call-sites for the XIP codec migration.
extension OutgoingMessageWriter {
    func encodeEncryptedAttachmentViaBridge(
        filename: String,
        mimeType: String,
        data: Data
    ) throws -> MessagingWriterBridge.EncryptedRemoteAttachment {
        try MessagingWriterBridge.encodeEncryptedAttachment(
            filename: filename,
            mimeType: mimeType,
            data: data
        )
    }

    func prepareTextViaBridge(
        conversation: MessagingConversation,
        text: String
    ) async throws -> String {
        try await MessagingWriterBridge.prepareText(
            conversation: conversation,
            text: text
        )
    }

    func prepareRemoteAttachmentViaBridge(
        conversation: MessagingConversation,
        stored: StoredRemoteAttachment,
        replyParentDbId: String?
    ) async throws -> String {
        try await MessagingWriterBridge.prepareRemoteAttachment(
            conversation: conversation,
            stored: stored,
            replyParentDbId: replyParentDbId
        )
    }

    func prepareTextReplyViaBridge(
        conversation: MessagingConversation,
        text: String,
        replyParentDbId: String
    ) async throws -> String {
        try await MessagingWriterBridge.prepareTextReply(
            conversation: conversation,
            text: text,
            replyParentDbId: replyParentDbId
        )
    }
}

// ConversationExplosionWriter shim. See
// `MessagingWriterBridge.sendExplode` for the FIXME on the
// ExplodeSettings codec.
extension ConversationExplosionWriter {
    func sendExplodeViaBridge(
        conversation: MessagingConversation,
        expiresAt: Date
    ) async throws {
        try await MessagingWriterBridge.sendExplode(
            conversation: conversation,
            expiresAt: expiresAt
        )
    }
}

// A ReadReceiptWriter shim so the writer file itself doesn't import
// XMTPiOS but still has a one-liner to call.
extension ReadReceiptWriter {
    func sendReadReceiptViaBridge(conversation: MessagingConversation) async throws {
        try await MessagingWriterBridge.sendReadReceipt(conversation: conversation)
    }
}

// ReactionWriter shim. See `MessagingWriterBridge.sendReaction` for
// the FIXME on the XIP `Reaction` codec.
extension ReactionWriter {
    func sendReactionViaBridge(
        conversation: MessagingConversation,
        reference: String,
        action: MessagingWriterBridge.ReactionActionBridge,
        emoji: String,
        referenceInboxId: String,
        shouldPush: Bool
    ) async throws {
        try await MessagingWriterBridge.sendReaction(
            conversation: conversation,
            reference: reference,
            action: action,
            emoji: emoji,
            referenceInboxId: referenceInboxId,
            shouldPush: shouldPush
        )
    }
}

// ReplyMessageWriter shim. See `MessagingWriterBridge.sendTextReply`
// for the FIXME on the XIP `Reply` codec.
extension ReplyMessageWriter {
    func sendTextReplyViaBridge(
        conversation: MessagingConversation,
        replyText: String,
        parentMessageId: String
    ) async throws -> String {
        try await MessagingWriterBridge.sendTextReply(
            conversation: conversation,
            replyText: replyText,
            parentMessageId: parentMessageId
        )
    }

    func publishPreparedMessagesViaBridge(
        conversation: MessagingConversation
    ) async throws {
        try await MessagingWriterBridge.publishPreparedMessages(
            conversation: conversation
        )
    }
}

// MARK: - XMTPiOS.Group ConversationSender conformance helpers

/// `ensureInviteTag()` shim on raw `XMTPiOS.Group`. Delegates into the
/// abstraction-layer `MessagingGroup+CustomMetadata` so legacy
/// XMTPiOS-typed call sites still get the helper.
public extension XMTPiOS.Group {
    func ensureInviteTag() async throws {
        try await XMTPiOSMessagingGroup(xmtpGroup: self).ensureInviteTag()
    }
}

// MARK: - XMTPiOS.DecodedMessage predicates

/// XMTPiOS-typed copies of the `isProfileMessage` / `isTypingIndicator`
/// / `isReadReceipt` predicates. The abstraction-side equivalents live
/// on `MessagingMessage` (see `MessagingContentType+XIP.swift`); these
/// stay for call sites that hold a raw `DecodedMessage` and have not
/// wrapped it in `MessagingMessage`.
extension XMTPiOS.DecodedMessage {
    var isProfileMessage: Bool {
        guard let contentType = try? encodedContent.type else { return false }
        return contentType == ContentTypeProfileUpdate || contentType == ContentTypeProfileSnapshot
    }

    var isTypingIndicator: Bool {
        guard let contentType = try? encodedContent.type else { return false }
        return contentType.authorityID == ContentTypeTypingIndicator.authorityID
            && contentType.typeID == ContentTypeTypingIndicator.typeID
    }

    var isReadReceipt: Bool {
        guard let contentType = try? encodedContent.type else { return false }
        return contentType.authorityID == ContentTypeReadReceipt.authorityID
            && contentType.typeID == ContentTypeReadReceipt.typeID
    }
}

// MARK: - MessagingPermission → DB permission check

extension MessagingPermission {
    /// Pre-migration, callers switched on `XMTPiOS.PermissionOption.deny`
    /// to detect a "locked" conversation. The abstraction-layer
    /// equivalent is this predicate.
    var isLocked: Bool {
        self == .deny
    }
}
