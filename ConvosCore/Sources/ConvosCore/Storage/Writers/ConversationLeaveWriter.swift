import Foundation
@preconcurrency import XMTPiOS

public protocol ConversationLeaveWriterProtocol: Sendable {
    /// Self-removes the current user from the group via `leaveGroup()`, then
    /// applies the optimistic consent-hide (consent `.denied` + push-topic
    /// unsubscribe + local row hide) so the conversation leaves the UI while
    /// the MLS remove-commit finalizes async.
    ///
    /// The protocol forbids a super admin from leaving (and from being
    /// removed), so a super-admin leaver is demoted first. When the leaver is
    /// also the sole super admin, the role is transferred to a remaining
    /// member before the demotion so the group always keeps at least one
    /// super admin. `successorCandidates` is the remaining membership
    /// (excluding the leaver); the writer applies a human-preferred,
    /// agent-fallback tenure policy to pick who to promote.
    func leave(
        conversation: Conversation,
        successorCandidates: [LeaveSuccessorCandidate]
    ) async throws
}

/// A remaining group member the leave writer may promote to super admin when
/// the leaver is the sole super admin. Carries just enough for the
/// human-preferred, agent-fallback tenure policy.
public struct LeaveSuccessorCandidate: Sendable {
    public let inboxId: String
    public let isAgent: Bool
    public let joinedAt: Date?

    public init(inboxId: String, isAgent: Bool, joinedAt: Date?) {
        self.inboxId = inboxId
        self.isAgent = isAgent
        self.joinedAt = joinedAt
    }
}

/// The MLS-level operations the leave writer reaches through to the XMTP SDK.
/// Factored out so tests can assert the call sequence (super-admin transfer ->
/// self-demotion -> `leaveGroup`) without standing up a real MLS group.
/// Production implementation is `XMTPLeaveGroupOperations`;
/// `MockLeaveGroupOperations` backs the unit tests.
protocol LeaveGroupOperationsProtocol: Sendable {
    func currentInboxId() async throws -> String
    func superAdminInboxIds(conversationId: String) async throws -> [String]
    func promoteToSuperAdmin(inboxId: String, conversationId: String) async throws
    func demoteFromSuperAdmin(inboxId: String, conversationId: String) async throws
    func leaveGroup(conversationId: String) async throws
}

enum ConversationLeaveError: LocalizedError {
    case conversationNotFound(String)
    case notGroupConversation(String)

    var errorDescription: String? {
        switch self {
        case .conversationNotFound(let id):
            return "Conversation not found: \(id)"
        case .notGroupConversation(let id):
            return "Cannot leave non-group conversation: \(id)"
        }
    }
}

struct XMTPLeaveGroupOperations: LeaveGroupOperationsProtocol {
    let sessionStateManager: any SessionStateManagerProtocol

    func currentInboxId() async throws -> String {
        let inboxReady = try await sessionStateManager.waitForInboxReadyResult()
        return inboxReady.client.inboxId
    }

    func superAdminInboxIds(conversationId: String) async throws -> [String] {
        let (_, group) = try await findGroupConversation(conversationId: conversationId)
        return try group.listSuperAdmins()
    }

    func promoteToSuperAdmin(inboxId: String, conversationId: String) async throws {
        let (_, group) = try await findGroupConversation(conversationId: conversationId)
        try await group.addSuperAdmin(inboxId: inboxId)
    }

    func demoteFromSuperAdmin(inboxId: String, conversationId: String) async throws {
        let (_, group) = try await findGroupConversation(conversationId: conversationId)
        try await group.removeSuperAdmin(inboxId: inboxId)
    }

    func leaveGroup(conversationId: String) async throws {
        let (_, group) = try await findGroupConversation(conversationId: conversationId)
        try await group.leaveGroup()
    }

    private func findGroupConversation(
        conversationId: String
    ) async throws -> (XMTPiOS.Conversation, Group) {
        let inboxReady = try await sessionStateManager.waitForInboxReadyResult()
        guard let xmtpConversation = try await inboxReady.client.conversationsProvider.findConversation(
            conversationId: conversationId
        ) else {
            throw ConversationLeaveError.conversationNotFound(conversationId)
        }
        guard case .group(let group) = xmtpConversation else {
            throw ConversationLeaveError.notGroupConversation(conversationId)
        }
        return (xmtpConversation, group)
    }
}

/// @unchecked Sendable: both stored properties are immutable Sendable
/// references and every method is async with no shared mutable state.
final class ConversationLeaveWriter: ConversationLeaveWriterProtocol, @unchecked Sendable {
    private let operations: any LeaveGroupOperationsProtocol
    private let consentWriter: any ConversationConsentWriterProtocol

    init(
        operations: any LeaveGroupOperationsProtocol,
        consentWriter: any ConversationConsentWriterProtocol
    ) {
        self.operations = operations
        self.consentWriter = consentWriter
    }

    func leave(
        conversation: Conversation,
        successorCandidates: [LeaveSuccessorCandidate]
    ) async throws {
        // Self-remove from the MLS roster. Benign outcomes are logged and
        // swallowed so the optimistic consent-hide below still runs and the
        // conversation leaves the UI regardless:
        // - we're the last member, so libxmtp rejects the 1 -> 0 commit,
        // - the group is already gone locally or another admin removed us
        //   first (conversationNotFound / NotFound::MlsGroup) -- the leave's
        //   goal is already achieved, only the local hide remains.
        // The benign filter covers the whole flow because the not-found case
        // also surfaces from the pre-leave super-admin lookup, not just from
        // leaveGroup itself.
        do {
            let myInboxId = try await operations.currentInboxId()
            try await relinquishSuperAdminIfNeeded(
                conversationId: conversation.id,
                myInboxId: myInboxId,
                successorCandidates: successorCandidates
            )
            try await operations.leaveGroup(conversationId: conversation.id)
        } catch {
            guard Self.isBenignLeaveError(error) else { throw error }
            Log.info("Leave skipped for \(conversation.id): \(error.localizedDescription)")
        }

        // Optimistic hide, reusing the existing consent-hide path: consent
        // `.denied` + push-topic unsubscribe + local row hide. The MLS
        // remove-commit is finalized async by an authorized admin/agent.
        try await consentWriter.delete(conversation: conversation)
    }

    /// The protocol rejects `leaveGroup()` while the leaver is a super admin
    /// (super admins cannot be removed), so a super-admin leaver must be
    /// demoted before the leave. Protects the "group always keeps at least
    /// one super admin" invariant: when the leaver is the sole super admin,
    /// the preferred successor is promoted before the self-demotion. Awaited
    /// rather than best-effort: if the transfer or demotion can't land we
    /// abort the leave rather than strand the group with no super admin or
    /// fail the leave at the MLS layer.
    private func relinquishSuperAdminIfNeeded(
        conversationId: String,
        myInboxId: String,
        successorCandidates: [LeaveSuccessorCandidate]
    ) async throws {
        let superAdmins = try await operations.superAdminInboxIds(conversationId: conversationId)
        guard superAdmins.contains(myInboxId) else { return }

        if superAdmins.count == 1 {
            let ordered = Self.orderedSuccessorInboxIds(from: successorCandidates, excluding: myInboxId)
            guard let successor = ordered.first else {
                // No one left to promote: the leaver is effectively the last
                // member, so keep the role and let `leaveGroup()` resolve it
                // (the 1 -> 0 commit is rejected as a benign error).
                Log.warning("Leaving \(conversationId) as sole super admin with no successor to promote")
                return
            }
            try await operations.promoteToSuperAdmin(inboxId: successor, conversationId: conversationId)
            Log.info("Transferred super admin to \(successor) before leaving \(conversationId)")
        }

        try await operations.demoteFromSuperAdmin(inboxId: myInboxId, conversationId: conversationId)
        Log.info("Demoted self from super admin before leaving \(conversationId)")
    }

    /// Successor inbox ids in promotion-preference order. Human members come
    /// first, longest-tenured first (by `joinedAt`, unknown tenure last).
    /// Agents are only used as a fallback so a creator can still leave a group
    /// whose only remaining members are agents while the "at least one super
    /// admin" invariant holds.
    private static func orderedSuccessorInboxIds(
        from candidates: [LeaveSuccessorCandidate],
        excluding myInboxId: String
    ) -> [String] {
        let eligible = candidates.filter { $0.inboxId != myInboxId }
        let humans = eligible.filter { !$0.isAgent }.sorted(by: isLongerTenured)
        let agents = eligible.filter { $0.isAgent }.sorted(by: isLongerTenured)
        return (humans + agents).map { $0.inboxId }
    }

    /// Orders longest-tenured first; a known `joinedAt` always precedes an
    /// unknown one.
    private static func isLongerTenured(
        _ lhs: LeaveSuccessorCandidate,
        _ rhs: LeaveSuccessorCandidate
    ) -> Bool {
        switch (lhs.joinedAt, rhs.joinedAt) {
        case let (left?, right?): return left < right
        case (nil, _?): return false
        case (_?, nil): return true
        case (nil, nil): return false
        }
    }

    /// libxmtp surfaces MLS failures as FFI errors whose full message is only
    /// visible via `String(describing:)`. Benign cases on self-leave:
    /// - `LeaveCantProcessed` / "only one member": we're the last member and
    ///   the 1 -> 0 invariant rejects the commit.
    /// - `NotFound::MlsGroup`: a concurrent remove already took us out.
    /// - `conversationNotFound`: the client no longer has the group at all
    ///   (another admin removed us and the welcome/group was purged); the
    ///   local hide is all that's left to do.
    private static func isBenignLeaveError(_ error: any Error) -> Bool {
        if case ConversationLeaveError.conversationNotFound = error {
            return true
        }
        let description = String(describing: error)
        return description.contains("LeaveCantProcessed")
            || description.contains("cannot leave a group that has only one member")
            || description.contains("NotFound::MlsGroup")
    }
}
