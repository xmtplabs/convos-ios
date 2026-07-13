import Foundation
import GRDB
@preconcurrency import XMTPiOS

public protocol ConversationLeaveWriterProtocol: Sendable {
    /// Self-removes the current user from the group via `leaveGroup()`, then
    /// applies the optimistic consent-hide (consent `.denied` + push-topic
    /// unsubscribe + local row hide) so the conversation leaves the UI while
    /// the MLS remove-commit finalizes async.
    ///
    /// The protocol forbids a super admin from leaving (and from being
    /// removed), so a super-admin leaver is demoted first. When no other
    /// super admin would remain after the demotion (the leaver is the sole
    /// super admin, or every other super admin has announced their own
    /// departure), the role is transferred to a remaining member before the
    /// demotion so the group always keeps at least one super admin.
    /// `successorCandidates` is the remaining membership (excluding the
    /// leaver); the writer applies a human-preferred, agent-fallback tenure
    /// policy to pick who to promote.
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

public enum ConversationLeaveError: LocalizedError {
    case conversationNotFound(String)
    case notGroupConversation(String)
    /// The user's membership already ended (the MLS self-removal committed
    /// in this call, or a benign rejection showed it was already over or
    /// already pending), but the optimistic consent-hide failed afterwards.
    /// The user is off the group either way, so callers should treat the
    /// conversation as left; the hide converges on a later consent sync. Not
    /// thrown for the one benign rejection that keeps the user a member (the
    /// single-member group): there the raw hide error propagates instead, so
    /// the leave reads as failed and stays retryable.
    case hideFailedAfterLeave(String, underlying: any Error)
    /// The leaver is the last super admin not already departing, and no
    /// successor could be promoted: every candidate announced their own
    /// departure since the candidate snapshot was taken, or none remains.
    /// The leave aborts so the group is not left without an active super
    /// admin.
    case noViableSuccessor(String)

    public var errorDescription: String? {
        switch self {
        case .conversationNotFound(let id):
            return "Conversation not found: \(id)"
        case .notGroupConversation(let id):
            return "Cannot leave non-group conversation: \(id)"
        case let .hideFailedAfterLeave(id, underlying):
            return "Left conversation \(id) but hiding it failed: \(underlying.localizedDescription)"
        case .noViableSuccessor(let id):
            return "No viable super-admin successor remains in conversation: \(id)"
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

/// @unchecked Sendable: all stored properties are immutable Sendable
/// references and every method is async with no shared mutable state.
final class ConversationLeaveWriter: ConversationLeaveWriterProtocol, @unchecked Sendable {
    private let operations: any LeaveGroupOperationsProtocol
    private let consentWriter: any ConversationConsentWriterProtocol
    private let databaseReader: any DatabaseReader

    init(
        operations: any LeaveGroupOperationsProtocol,
        consentWriter: any ConversationConsentWriterProtocol,
        databaseReader: any DatabaseReader
    ) {
        self.operations = operations
        self.consentWriter = consentWriter
        self.databaseReader = databaseReader
    }

    func leave(
        conversation: Conversation,
        successorCandidates: [LeaveSuccessorCandidate]
    ) async throws {
        // Self-remove from the MLS roster. Benign outcomes are logged and
        // swallowed so the optimistic consent-hide below still runs and the
        // conversation leaves the UI regardless. Each benign case is also
        // classified by what it implies for the membership (see
        // `benignLeaveOutcome(for:)`) because that decides what a hide
        // failure afterwards means. The benign filter covers the whole flow
        // because the not-found case also surfaces from the pre-leave
        // super-admin lookup, not just from leaveGroup itself.
        var membershipEnded = true
        do {
            let myInboxId = try await operations.currentInboxId()
            try await relinquishSuperAdminIfNeeded(
                conversationId: conversation.id,
                myInboxId: myInboxId,
                successorCandidates: successorCandidates
            )
            try await operations.leaveGroup(conversationId: conversation.id)
        } catch {
            guard let outcome = Self.benignLeaveOutcome(for: error) else { throw error }
            membershipEnded = outcome == .membershipEnded
            Log.info("Leave skipped for \(conversation.id): \(error.localizedDescription)")
        }

        // Optimistic hide, reusing the existing consent-hide path: consent
        // `.denied` + push-topic unsubscribe + local row hide. The MLS
        // remove-commit is finalized async by an authorized admin/agent.
        // When the membership already ended above (the self-removal
        // committed, or a benign rejection showed it was already over), a
        // failure here is surfaced as a typed error: the caller must still
        // treat the conversation as left rather than as a failed leave. When
        // the user is still a member instead (the single-member rejection),
        // the raw hide error propagates and the leave reads as failed and
        // retryable; announcing a completed leave there would be false.
        do {
            try await consentWriter.delete(conversation: conversation)
        } catch {
            guard membershipEnded else { throw error }
            throw ConversationLeaveError.hideFailedAfterLeave(conversation.id, underlying: error)
        }
    }

    /// The protocol rejects `leaveGroup()` while the leaver is a super admin
    /// (super admins cannot be removed), so a super-admin leaver must be
    /// demoted before the leave. Protects the "group always keeps at least
    /// one super admin" invariant: when no other super admin remains viable -
    /// there is none, or every other one has announced their own departure -
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

        let otherSuperAdmins = superAdmins.filter { $0 != myInboxId }
        let keepsAViableSuperAdmin: Bool = try await hasViableOtherSuperAdmin(
            among: otherSuperAdmins,
            conversationId: conversationId
        )
        if !keepsAViableSuperAdmin {
            let ordered = Self.orderedSuccessorInboxIds(from: successorCandidates, excluding: myInboxId)
            if ordered.isEmpty && otherSuperAdmins.isEmpty {
                // No one left to promote: the leaver is effectively the last
                // member, so keep the role and let `leaveGroup()` resolve it
                // (the 1 -> 0 commit is rejected as a benign error).
                Log.warning("Leaving \(conversationId) as sole super admin with no successor to promote")
                return
            }
            guard !ordered.isEmpty else {
                // Every other super admin announced their own departure and
                // no other member remains to promote: demoting self would let
                // the group finalize into zero super admins once those leaves
                // complete.
                throw ConversationLeaveError.noViableSuccessor(conversationId)
            }
            try await promoteFirstViableSuccessor(from: ordered, conversationId: conversationId)
        }

        try await operations.demoteFromSuperAdmin(inboxId: myInboxId, conversationId: conversationId)
        Log.info("Demoted self from super admin before leaving \(conversationId)")
    }

    /// True when at least one of the other super admins has not announced
    /// their own departure, so the group still has a super admin after the
    /// leaver's self-demotion. A departing super admin does not count: their
    /// pending removal would finalize the group into zero super admins.
    private func hasViableOtherSuperAdmin(
        among inboxIds: [String],
        conversationId: String
    ) async throws -> Bool {
        for inboxId in inboxIds {
            let departing = try await hasAnnouncedDeparture(inboxId: inboxId, conversationId: conversationId)
            if !departing { return true }
        }
        return false
    }

    /// Tries candidates in preference order. The snapshot behind the
    /// candidates is taken before the leave runs, so a candidate can have
    /// left the group meanwhile and their promotion is rejected; falling
    /// back to the next candidate keeps a valid leave from aborting on a
    /// stale snapshot. A candidate can also have announced their own
    /// departure since the snapshot; libxmtp still accepts a pending leaver
    /// in the admin list, so the departure markers are re-checked right
    /// before each attempt and marked candidates are skipped. Only when no
    /// candidate can be promoted does an error propagate, aborting the leave
    /// to protect the super-admin invariant.
    private func promoteFirstViableSuccessor(
        from orderedInboxIds: [String],
        conversationId: String
    ) async throws {
        var lastError: (any Error)?
        for inboxId in orderedInboxIds {
            guard try await !hasAnnouncedDeparture(inboxId: inboxId, conversationId: conversationId) else {
                Log.info("Skipping successor \(inboxId) in \(conversationId): departure announced since the candidate snapshot")
                continue
            }
            do {
                try await operations.promoteToSuperAdmin(inboxId: inboxId, conversationId: conversationId)
                Log.info("Transferred super admin to \(inboxId) before leaving \(conversationId)")
                return
            } catch {
                Log.warning("Promotion of \(inboxId) in \(conversationId) failed, trying next candidate: \(error.localizedDescription)")
                lastError = error
            }
        }
        // Callers guarantee a non-empty candidate list, so reaching this
        // point means every promotion attempt failed or was skipped.
        if let lastError { throw lastError }
        throw ConversationLeaveError.noViableSuccessor(conversationId)
    }

    /// True when a local departure marker exists for the inbox: the member
    /// announced they are leaving and their remove-commit hasn't finalized,
    /// so they must not become the group's super admin.
    private func hasAnnouncedDeparture(
        inboxId: String,
        conversationId: String
    ) async throws -> Bool {
        try await databaseReader.read { db in
            try DBMemberDeparture
                .filter(DBMemberDeparture.Columns.conversationId == conversationId)
                .filter(DBMemberDeparture.Columns.inboxId == inboxId)
                .fetchCount(db) > 0
        }
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

    /// What a benign leave rejection implies for the user's membership. The
    /// distinction decides what a subsequent consent-hide failure means for
    /// the caller.
    private enum BenignLeaveOutcome {
        /// The membership is already over, or its removal is already pending
        /// finalization - the same state a successful `leaveGroup()` leaves
        /// behind. A hide failure afterwards still means the user is off the
        /// group.
        case membershipEnded
        /// The rejection keeps the user a member: they are the group's sole
        /// member and libxmtp forbids the 1 -> 0 commit. Only the local hide
        /// ends this membership, so a hide failure means the leave failed.
        case stillMember
    }

    /// libxmtp surfaces MLS failures as FFI errors whose full message is only
    /// visible via `String(describing:)`. `LeaveCantProcessed` is the wrapper
    /// for every leave validation failure - including super-admin and DM
    /// rejections that mean the user is still a member - so matching on the
    /// wrapper name alone would turn those into a silent local hide. Only the
    /// specific rejections whose goal is already achieved (or unachievable by
    /// protocol) are benign, matched by their stable libxmtp messages, and
    /// each carries what it implies for the membership:
    /// - "only one member" (still a member): libxmtp raises it only when the
    ///   user is a member and the sole occupant; the 1 -> 0 invariant rejects
    ///   the commit and the group is dead by protocol, but only the local
    ///   hide removes it from view.
    /// - "only a member of the group can send a leave request" (ended): a
    ///   concurrent removal already took us out before the leave-request
    ///   landed.
    /// - "already exists in the pending leave list" (ended): a leave-request
    ///   from a retry or another installation is already awaiting
    ///   finalization.
    /// - `NotFound::MlsGroup` (ended): a concurrent remove already deleted
    ///   the group.
    /// - `conversationNotFound` (ended): the client no longer has the group
    ///   at all (another admin removed us and the welcome/group was purged);
    ///   the local hide is all that's left to do.
    /// Returns nil for any other error: not benign, the leave failed.
    private static func benignLeaveOutcome(for error: any Error) -> BenignLeaveOutcome? {
        if case ConversationLeaveError.conversationNotFound = error {
            return .membershipEnded
        }
        let description = String(describing: error)
        if description.contains("cannot leave a group that has only one member") {
            return .stillMember
        }
        let membershipEndedFragments = [
            "only a member of the group can send a leave request",
            "inbox ID already exists in the pending leave list",
            "NotFound::MlsGroup",
        ]
        if membershipEndedFragments.contains(where: { description.contains($0) }) {
            return .membershipEnded
        }
        return nil
    }
}
