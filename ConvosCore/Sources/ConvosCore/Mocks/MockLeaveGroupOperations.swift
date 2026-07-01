import Foundation
import os

/// In-memory stub for `LeaveGroupOperationsProtocol`. Records the sequence of
/// MLS-level calls the leave writer makes and lets tests inject the super-admin
/// roster and per-step failures, enough to assert the super-admin-transfer ->
/// leaveGroup flow without standing up a real XMTP group.
final class MockLeaveGroupOperations: LeaveGroupOperationsProtocol, @unchecked Sendable {
    enum Call: Equatable, Sendable {
        case currentInboxId
        case superAdminInboxIds(conversationId: String)
        case promoteToSuperAdmin(inboxId: String, conversationId: String)
        case leaveGroup(conversationId: String)
    }

    private let lock: OSAllocatedUnfairLock<State> = .init(initialState: State())

    private struct State {
        var calls: [Call] = []
        var inboxId: String = "inbox-self"
        var superAdmins: [String] = []
        var promoteError: (any Error)?
        var leaveError: (any Error)?
    }

    var calls: [Call] { lock.withLock { $0.calls } }

    func setInboxId(_ inboxId: String) {
        lock.withLock { $0.inboxId = inboxId }
    }

    func setSuperAdmins(_ ids: [String]) {
        lock.withLock { $0.superAdmins = ids }
    }

    func failPromote(with error: any Error) {
        lock.withLock { $0.promoteError = error }
    }

    func failLeave(with error: any Error) {
        lock.withLock { $0.leaveError = error }
    }

    func currentInboxId() async throws -> String {
        lock.withLock { state in
            state.calls.append(.currentInboxId)
            return state.inboxId
        }
    }

    func superAdminInboxIds(conversationId: String) async throws -> [String] {
        lock.withLock { state in
            state.calls.append(.superAdminInboxIds(conversationId: conversationId))
            return state.superAdmins
        }
    }

    func promoteToSuperAdmin(inboxId: String, conversationId: String) async throws {
        let error: (any Error)? = lock.withLock { state in
            state.calls.append(.promoteToSuperAdmin(inboxId: inboxId, conversationId: conversationId))
            return state.promoteError
        }
        if let error { throw error }
    }

    func leaveGroup(conversationId: String) async throws {
        let error: (any Error)? = lock.withLock { state in
            state.calls.append(.leaveGroup(conversationId: conversationId))
            return state.leaveError
        }
        if let error { throw error }
    }
}
