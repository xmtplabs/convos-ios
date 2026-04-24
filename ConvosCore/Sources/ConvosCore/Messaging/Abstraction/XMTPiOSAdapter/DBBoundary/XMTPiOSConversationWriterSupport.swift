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
