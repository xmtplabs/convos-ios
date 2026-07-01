import Foundation
@preconcurrency import XMTPiOS

public protocol ConversationLeaveWriterProtocol: Sendable {
    /// Self-removes the current user from the group via `leaveGroup()`, then
    /// applies the optimistic consent-hide (consent `.denied` + push-topic
    /// unsubscribe + local row hide) so the conversation leaves the UI while
    /// the MLS remove-commit finalizes async.
    ///
    /// When the leaver is the sole super admin, the super-admin role is first
    /// transferred to a remaining member so the group always keeps at least
    /// one super admin. `successorCandidates` is the remaining membership
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
/// `leaveGroup`) without standing up a real MLS group. Production
/// implementation is `XMTPLeaveGroupOperations`; `MockLeaveGroupOperations`
/// backs the unit tests.
protocol LeaveGroupOperationsProtocol: Sendable {
    func currentInboxId() async throws -> String
    func superAdminInboxIds(conversationId: String) async throws -> [String]
    func promoteToSuperAdmin(inboxId: String, conversationId: String) async throws
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
        let myInboxId = try await operations.currentInboxId()

        try await transferSuperAdminIfNeeded(
            conversationId: conversation.id,
            myInboxId: myInboxId,
            successorCandidates: successorCandidates
        )

        // Self-remove from the MLS roster. Benign outcomes are logged and
        // swallowed so the optimistic consent-hide below still runs and the
        // conversation leaves the UI regardless:
        // - we're the last member, so libxmtp rejects the 1 -> 0 commit,
        // - a concurrent remove already took us out of the group.
        do {
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

    /// Protects the "group always keeps at least one super admin" invariant.
    /// Only acts when the leaver is the sole super admin, then promotes the
    /// preferred successor before leaving. Awaited rather than best-effort: if
    /// the transfer can't land we abort the leave rather than strand the group
    /// with no super admin.
    private func transferSuperAdminIfNeeded(
        conversationId: String,
        myInboxId: String,
        successorCandidates: [LeaveSuccessorCandidate]
    ) async throws {
        let superAdmins = try await operations.superAdminInboxIds(conversationId: conversationId)
        let isSoleSuperAdmin = superAdmins.contains(myInboxId) && superAdmins.count == 1
        guard isSoleSuperAdmin else { return }

        let ordered = Self.orderedSuccessorInboxIds(from: successorCandidates, excluding: myInboxId)
        guard let successor = ordered.first else {
            Log.warning("Leaving \(conversationId) as sole super admin with no successor to promote")
            return
        }

        try await operations.promoteToSuperAdmin(inboxId: successor, conversationId: conversationId)
        Log.info("Transferred super admin to \(successor) before leaving \(conversationId)")
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
    /// visible via `String(describing:)`. Two benign cases on self-leave:
    /// - `LeaveCantProcessed` / "only one member": we're the last member and
    ///   the 1 -> 0 invariant rejects the commit.
    /// - `NotFound::MlsGroup`: a concurrent remove already took us out.
    private static func isBenignLeaveError(_ error: any Error) -> Bool {
        let description = String(describing: error)
        return description.contains("LeaveCantProcessed")
            || description.contains("cannot leave a group that has only one member")
            || description.contains("NotFound::MlsGroup")
    }
}
