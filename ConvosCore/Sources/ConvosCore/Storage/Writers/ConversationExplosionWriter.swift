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

        // Every MLS boundary call below runs through `runBoundedMLSOp`: bounded
        // timeout, logged failure, non-fatal. The MLS teardown (removeMembers +
        // leaveGroup) is the source of truth for "group ends"; the codec
        // `ExplodeSettings` send is a best-effort hint so receivers can hide the
        // conversation ahead of the MLS commit arriving. Any single leg failing
        // must not abort the remaining legs — partial-destruction leaves the
        // group half-gone on the network, which is strictly worse than a
        // best-effort full sweep where some pieces may still retry later.
        await runBoundedMLSOp("ExplodeSettings send") { [operations] in
            try await operations.sendExplode(conversationId: conversationId, expiresAt: expiresAt)
        }
        QAEvent.emit(.conversation, "exploded", ["id": conversationId])

        // Local `expiresAt` makes the sender's UI hide the conversation
        // immediately. `ConversationsRepository` filters on `expiresAt > Date()`,
        // so a past value is the soft-delete trigger.
        await runBoundedMetadataOp("updateExpiresAt") { [metadataWriter] in
            try await metadataWriter.updateExpiresAt(expiresAt, for: conversationId)
        }

        // Remove every other member from the MLS group (filtered list,
        // creator excluded). Emits GroupUpdated removal events that other
        // clients pick up even if they missed the ExplodeSettings message
        // (e.g. offline at send time).
        await runBoundedMetadataOp("removeMembers") { [metadataWriter] in
            try await metadataWriter.removeMembers(otherMemberInboxIds, from: conversationId)
        }

        // Creator leaves the group. In the per-conversation-identity era
        // this step didn't exist — the whole inbox was destroyed. With a single
        // shared inbox we can't destroy keys (they secure every other conversation),
        // so the cleanest exit is an explicit self-remove via `leaveGroup()`. The
        // XMTP SDK sends the MLS commit that takes us out of the group.
        // `denyConsent` was used pre-C9 as a belt-and-suspenders to keep the
        // conversation from re-syncing — it's now redundant with `leaveGroup()`
        // (we're out of the group so there's nothing left to sync), but
        // preserved as a no-op guard in case the leave operation is interrupted.
        let left = await runBoundedMLSOp("leaveGroup") { [operations] in
            try await operations.leaveGroup(conversationId: conversationId)
        }
        if left {
            Log.info("Creator left exploded group: \(conversationId)")
        } else {
            await runBoundedMLSOp("denyConsent fallback") { [operations] in
                try await operations.denyConsent(conversationId: conversationId)
            }
        }
    }

    func scheduleExplosion(conversationId: String, expiresAt: Date) async throws {
        Log.info("Scheduling explosion for \(expiresAt)...")
        await runBoundedMLSOp("ExplodeSettings schedule") { [operations] in
            try await operations.sendExplode(conversationId: conversationId, expiresAt: expiresAt)
        }

        await runBoundedMetadataOp("updateExpiresAt (schedule)") { [metadataWriter] in
            try await metadataWriter.updateExpiresAt(expiresAt, for: conversationId)
        }

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

    /// Bounded best-effort wrapper for a single MLS boundary call. Any thrown
    /// error or timeout is logged and swallowed — the caller continues. Every
    /// MLS reach-through in this writer goes through here so the failure
    /// semantics are uniform: no one leg's flake can abort the other legs.
    /// Returns `true` on success, `false` on timeout or throw; callers who
    /// branch on the result (e.g. leave → denyConsent fallback) use that.
    @discardableResult
    private func runBoundedMLSOp(
        _ name: String,
        timeout: TimeInterval = 20,
        _ body: @escaping @Sendable () async throws -> Void
    ) async -> Bool {
        do {
            try await withTimeout(seconds: timeout, operation: body)
            Log.info("\(name) succeeded")
            return true
        } catch {
            Log.error("\(name) failed: \(error.localizedDescription)")
            return false
        }
    }

    /// Bounded wrapper for a metadata-writer call. Shorter timeout than MLS
    /// ops because these are local-DB + prepared-XMTP-message operations
    /// rather than full network commits; failures here are even less fatal
    /// (DB retry on next launch, XMTP metadata delivered lazily).
    @discardableResult
    private func runBoundedMetadataOp(
        _ name: String,
        timeout: TimeInterval = 20,
        _ body: @escaping @Sendable () async throws -> Void
    ) async -> Bool {
        do {
            try await withTimeout(seconds: timeout, operation: body)
            return true
        } catch {
            Log.error("\(name) failed: \(error.localizedDescription)")
            return false
        }
    }
}
