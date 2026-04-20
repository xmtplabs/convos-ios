import Foundation
@preconcurrency import XMTPiOS

public protocol ConversationExplosionWriterProtocol: Sendable {
    func explodeConversation(conversationId: String, memberInboxIds: [String]) async throws
    func scheduleExplosion(conversationId: String, expiresAt: Date) async throws
}

/// The MLS-level operations the explosion writer needs to reach through to
/// the XMTP SDK. Factored out so tests can assert the call sequence
/// (`sendExplode` → remove members → `leaveGroup` → fallback
/// `updateConsentState`) without standing up a real MLS group. Production
/// implementation is `XMTPExplodeGroupOperations`; `MockExplodeGroupOperations`
/// backs the unit tests.
protocol ExplodeGroupOperationsProtocol: Sendable {
    func currentInboxId() async throws -> String
    func sendExplode(conversationId: String, expiresAt: Date) async throws
    func leaveGroup(conversationId: String) async throws
    func denyConsent(conversationId: String) async throws
}

enum ConversationExplosionError: LocalizedError {
    case conversationNotFound(String)
    case notGroupConversation(String)

    var errorDescription: String? {
        switch self {
        case .conversationNotFound(let id):
            return "Conversation not found: \(id)"
        case .notGroupConversation(let id):
            return "Cannot explode non-group conversation: \(id)"
        }
    }
}

struct XMTPExplodeGroupOperations: ExplodeGroupOperationsProtocol {
    let sessionStateManager: any SessionStateManagerProtocol

    func currentInboxId() async throws -> String {
        let inboxReady = try await sessionStateManager.waitForInboxReadyResult()
        return inboxReady.client.inboxId
    }

    func sendExplode(conversationId: String, expiresAt: Date) async throws {
        let (xmtpConversation, _) = try await findGroupConversation(conversationId: conversationId)
        nonisolated(unsafe) let unsafeConversation = xmtpConversation
        try await unsafeConversation.sendExplode(expiresAt: expiresAt)
    }

    func leaveGroup(conversationId: String) async throws {
        let (_, group) = try await findGroupConversation(conversationId: conversationId)
        try await group.leaveGroup()
    }

    func denyConsent(conversationId: String) async throws {
        let (_, group) = try await findGroupConversation(conversationId: conversationId)
        try await group.updateConsentState(state: .denied)
    }

    private func findGroupConversation(
        conversationId: String
    ) async throws -> (XMTPiOS.Conversation, Group) {
        let inboxReady = try await sessionStateManager.waitForInboxReadyResult()
        guard let xmtpConversation = try await inboxReady.client.conversationsProvider.findConversation(
            conversationId: conversationId
        ) else {
            throw ConversationExplosionError.conversationNotFound(conversationId)
        }

        guard case .group(let group) = xmtpConversation else {
            throw ConversationExplosionError.notGroupConversation(conversationId)
        }

        return (xmtpConversation, group)
    }
}

final class ConversationExplosionWriter: ConversationExplosionWriterProtocol, @unchecked Sendable {
    private let operations: any ExplodeGroupOperationsProtocol
    private let metadataWriter: any ConversationMetadataWriterProtocol

    init(
        operations: any ExplodeGroupOperationsProtocol,
        metadataWriter: any ConversationMetadataWriterProtocol
    ) {
        self.operations = operations
        self.metadataWriter = metadataWriter
    }

    func explodeConversation(conversationId: String, memberInboxIds: [String]) async throws {
        let expiresAt = Date()

        // Filter the creator's own inboxId out of the member list. The
        // ViewModel passes `conversation.members.map { $0.profile.inboxId }`
        // which includes the current user. MLS rejects self-removal via
        // `removeMembers` — the creator must leave via `leaveGroup()` at the end.
        // Without this filter the remove step throws and the explode degrades to
        // "the codec message went out but nothing else happened."
        let currentInboxId = try await operations.currentInboxId()
        let otherMemberInboxIds = memberInboxIds.filter { $0 != currentInboxId }

        // Every leg below runs through `runBoundedOp`: bounded timeout,
        // logged failure, non-fatal. The MLS teardown (removeMembers +
        // leaveGroup) is the source of truth for "group ends"; the codec
        // `ExplodeSettings` send is a best-effort hint so receivers can hide the
        // conversation ahead of the MLS commit arriving. Any single leg failing
        // must not abort the remaining legs — partial-destruction leaves the
        // group half-gone on the network, which is strictly worse than a
        // best-effort full sweep where some pieces may still retry later.
        await runBoundedOp("ExplodeSettings send", logSuccess: true) { [operations] in
            try await operations.sendExplode(conversationId: conversationId, expiresAt: expiresAt)
        }
        QAEvent.emit(.conversation, "exploded", ["id": conversationId])

        // Local `expiresAt` makes the sender's UI hide the conversation
        // immediately. `ConversationsRepository` filters on `expiresAt > Date()`,
        // so a past value is the soft-delete trigger.
        await runBoundedOp("updateExpiresAt") { [metadataWriter] in
            try await metadataWriter.updateExpiresAt(expiresAt, for: conversationId)
        }

        // Remove every other member from the MLS group (filtered list,
        // creator excluded). Emits GroupUpdated removal events that other
        // clients pick up even if they missed the ExplodeSettings message
        // (e.g. offline at send time).
        await runBoundedOp("removeMembers") { [metadataWriter] in
            try await metadataWriter.removeMembers(otherMemberInboxIds, from: conversationId)
        }

        // The creator leaves the group via an explicit self-remove; the
        // XMTP SDK sends the MLS commit that takes us out. `denyConsent` is
        // a belt-and-suspenders fallback for when `leaveGroup()` gets
        // interrupted — we're out of the group on success so there's
        // nothing left to sync, but denying consent still blocks the
        // conversation from re-syncing if the leave commit never landed.
        let left = await runBoundedOp("leaveGroup", logSuccess: true) { [operations] in
            try await operations.leaveGroup(conversationId: conversationId)
        }
        if left {
            Log.info("Creator left exploded group: \(conversationId)")
        } else {
            await runBoundedOp("denyConsent fallback", logSuccess: true) { [operations] in
                try await operations.denyConsent(conversationId: conversationId)
            }
        }
    }

    func scheduleExplosion(conversationId: String, expiresAt: Date) async throws {
        Log.info("Scheduling explosion for \(expiresAt)...")
        // Unlike the immediate-explode path where partial failure is better
        // than an aborted sweep, scheduling is a single user-facing action —
        // if the `ExplodeSettings` broadcast fails the schedule didn't
        // actually propagate, and the caller needs to see that so the UI
        // can land on `.error` instead of falsely showing `.scheduled`.
        try await withTimeout(seconds: 20) { [operations] in
            try await operations.sendExplode(conversationId: conversationId, expiresAt: expiresAt)
        }
        try await metadataWriter.updateExpiresAt(expiresAt, for: conversationId)

        NotificationCenter.default.post(
            name: .conversationScheduledExplosion,
            object: nil,
            userInfo: [
                "conversationId": conversationId,
                "expiresAt": expiresAt
            ]
        )
        Log.info("Explosion scheduled for \(expiresAt)")
    }

    /// Bounded best-effort wrapper for a single leg of the explode sweep. Any
    /// thrown error or timeout is logged and swallowed so the remaining legs
    /// still run — partial destruction is strictly worse than a best-effort
    /// full sweep. Returns `true` on success, `false` on throw or timeout;
    /// callers that branch on the result (e.g. `leaveGroup` → `denyConsent`
    /// fallback) read it. `logSuccess` toggles a success log line, set to
    /// true on the network-visible MLS legs so telemetry can confirm they
    /// completed.
    @discardableResult
    private func runBoundedOp(
        _ name: String,
        timeout: TimeInterval = 20,
        logSuccess: Bool = false,
        _ body: @escaping @Sendable () async throws -> Void
    ) async -> Bool {
        do {
            try await withTimeout(seconds: timeout, operation: body)
            if logSuccess {
                Log.info("\(name) succeeded")
            }
            return true
        } catch {
            Log.error("\(name) failed: \(error.localizedDescription)")
            return false
        }
    }
}
