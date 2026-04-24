import ConvosProfiles
import Foundation
@preconcurrency import XMTPiOS

// Stage 3 migration (audit §5.3): the XMTPiOS-specific helpers that
// used to live inside `Storage/Writers/ConversationWriter.swift`
// (`fileprivate extension XMTPiOS.Member`, `extension XMTPiOS.Conversation`
// `{ creatorInboxId }`, etc.) relocated here so the writer file itself
// no longer imports XMTPiOS. Everything in this file is a thin boundary
// between the SDK type and a Convos-owned value.

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

/// Stage 3 migration: the Storage writers now receive
/// `[MessagingMember]` from `MessagingGroup.members()`. This extension
/// lives beside the `XMTPiOS.Member` bridge so the two translators sit
/// together.
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
        get throws {
            switch self {
            case .group(let group):
                return try group.inviteTag
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

/// Stage 3 migration: the Storage writers now receive a
/// `MessagingConversationDebugInfo` snapshot from `MessagingGroup`.
/// Same mapping as the XMTPiOS counterpart.
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

// MARK: - Stage 3 writer bridges

/// Stage 3 migration (audit §5.3) helper for writers that need to
/// invoke an XMTPiOS-specific operation on a `MessagingConversation`
/// until the corresponding Messaging* surface lands (Stage 6). Each
/// helper downcasts to the XMTPiOS adapter and throws a clear error
/// on any other backend (e.g. DTU in Stage 5+).
enum MessagingWriterBridge {
    /// Send a read-receipt on a `MessagingConversation`.
    /// FIXME(stage6): surface `sendReadReceipt()` on
    /// `MessagingConversationCore` once the `ReadReceiptCodec`
    /// migrates to the abstraction layer.
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
    /// FIXME(stage6): `Reply` / `ContentTypeText` / `ContentTypeReply`
    /// are XMTPiOS XIP codec values. Surface a Messaging* equivalent
    /// once the codecs migrate.
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
    /// FIXME(stage6): the `Reaction` struct + `ReactionV2Codec` are
    /// XMTPiOS XIP values. Once the codec surface moves to the
    /// abstraction, reimplement via `conversation.core.sendOptimistic(
    /// encodedContent:options:)`.
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

// A ReadReceiptWriter shim so the writer file itself doesn't import
// XMTPiOS but still has a one-liner to call.
extension ReadReceiptWriter {
    func sendReadReceiptViaBridge(conversation: MessagingConversation) async throws {
        try await MessagingWriterBridge.sendReadReceipt(conversation: conversation)
    }
}

// ReactionWriter shim. See `MessagingWriterBridge.sendReaction` for
// the Stage 6 FIXME on the XIP `Reaction` codec.
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
// for the Stage 6 FIXME on the XIP `Reply` codec.
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

// MARK: - XMTPiOS.DecodedMessage predicates

/// Stage 3 migration (audit §5.3): the `isProfileMessage`/
/// `isTypingIndicator` / `isReadReceipt` predicates used to live in
/// `Storage/Writers/ConversationWriter.swift` on `XMTPiOS.DecodedMessage`.
/// The abstraction-side equivalents now live on `MessagingMessage`
/// (see `MessagingContentType+XIP.swift`). These XMTPiOS-facing
/// copies remain here for Stage 4 call sites that have not yet
/// wrapped their `DecodedMessage` in `MessagingMessage`.
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
