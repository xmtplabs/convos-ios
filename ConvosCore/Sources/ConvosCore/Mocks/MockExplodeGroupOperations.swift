import Foundation
import os

/// In-memory stub for `ExplodeGroupOperationsProtocol`. Records the
/// sequence of MLS-level calls the explosion writer makes and lets the
/// test inject failures on individual steps — enough to assert the
/// remove-all-then-leave flow without standing up a real XMTP group.
final class MockExplodeGroupOperations: ExplodeGroupOperationsProtocol, @unchecked Sendable {
    enum Call: Equatable, Sendable {
        case currentInboxId
        case sendExplode(conversationId: String, expiresAt: Date)
        case leaveGroup(conversationId: String)
        case denyConsent(conversationId: String)
    }

    private let lock: OSAllocatedUnfairLock<State> = .init(initialState: State())

    private struct State {
        var calls: [Call] = []
        var inboxId: String = "inbox-self"
        var sendExplodeError: (any Error)?
        var leaveGroupError: (any Error)?
        var denyConsentError: (any Error)?
    }

    var calls: [Call] { lock.withLock { $0.calls } }

    func setInboxId(_ inboxId: String) {
        lock.withLock { $0.inboxId = inboxId }
    }

    func failSendExplode(with error: any Error) {
        lock.withLock { $0.sendExplodeError = error }
    }

    func failLeaveGroup(with error: any Error) {
        lock.withLock { $0.leaveGroupError = error }
    }

    func failDenyConsent(with error: any Error) {
        lock.withLock { $0.denyConsentError = error }
    }

    func currentInboxId() async throws -> String {
        lock.withLock { state in
            state.calls.append(.currentInboxId)
            return state.inboxId
        }
    }

    func sendExplode(conversationId: String, expiresAt: Date) async throws {
        let error: (any Error)? = lock.withLock { state in
            state.calls.append(.sendExplode(conversationId: conversationId, expiresAt: expiresAt))
            return state.sendExplodeError
        }
        if let error { throw error }
    }

    func leaveGroup(conversationId: String) async throws {
        let error: (any Error)? = lock.withLock { state in
            state.calls.append(.leaveGroup(conversationId: conversationId))
            return state.leaveGroupError
        }
        if let error { throw error }
    }

    func denyConsent(conversationId: String) async throws {
        let error: (any Error)? = lock.withLock { state in
            state.calls.append(.denyConsent(conversationId: conversationId))
            return state.denyConsentError
        }
        if let error { throw error }
    }
}
