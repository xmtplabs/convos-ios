import Foundation
@preconcurrency import XMTPiOS

public protocol ConversationExplosionWriterProtocol: Sendable {
    func explodeConversation(conversationId: String, memberInboxIds: [String]) async throws
    func scheduleExplosion(conversationId: String, expiresAt: Date) async throws
    func peerSelfLeaveExpiredConversation(conversationId: String) async
}

/// The MLS-level operations the explosion writer needs to reach through to
/// the XMTP SDK. Factored out so tests can assert the call sequence
/// (`sendExplode` → remove members → `denyConsent`) without standing up a
/// real MLS group. Production implementation is `XMTPExplodeGroupOperations`;
/// `MockExplodeGroupOperations` backs the unit tests.
protocol ExplodeGroupOperationsProtocol: Sendable {
    func currentInboxId() async throws -> String
    func sendExplode(conversationId: String, expiresAt: Date) async throws
    func denyConsent(conversationId: String) async throws
    func peerLeaveExpiredGroup(conversationId: String) async throws
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

    func denyConsent(conversationId: String) async throws {
        let (_, group) = try await findGroupConversation(conversationId: conversationId)
        try await group.updateConsentState(state: .denied)
    }

    func peerLeaveExpiredGroup(conversationId: String) async throws {
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
        // which includes the current user, and MLS rejects self-removal via
        // `removeMembers`. Without this filter the remove step throws and the
        // explode degrades to "the codec message went out but nothing else
        // happened."
        let currentInboxId = try await operations.currentInboxId()
        let otherMemberInboxIds = memberInboxIds.filter { $0 != currentInboxId }

        // Every leg below runs through `runBoundedOp`: bounded timeout,
        // logged failure, non-fatal. `removeMembers` is the source of truth
        // for "group ends" from the other participants' perspective; the
        // codec `ExplodeSettings` send is a best-effort hint so receivers
        // can hide the conversation ahead of the MLS commit arriving. Any
        // single leg failing must not abort the remaining legs — partial-
        // destruction leaves the group half-gone on the network, which is
        // strictly worse than a best-effort full sweep where some pieces
        // may still retry later.
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

        // Deny consent so the exploded conversation doesn't re-sync
        // locally. `removeMembers` upstream is the real teardown signal to
        // other participants; consent just prevents the local client from
        // pulling the conversation back in. libxmtp rejects an explicit
        // `leaveGroup()` here because the creator is the sole remaining
        // member after `removeMembers`, and a 1 → 0 MLS commit has nobody
        // left to validate it.
        await runBoundedOp("denyConsent", logSuccess: true) { [operations] in
            try await operations.denyConsent(conversationId: conversationId)
        }
    }

    /// Peer-side cleanup when a scheduled explode's timer fires on a
    /// non-creator device. The peer walks out of the MLS group on their own
    /// rather than waiting for the creator to kick them — if the creator is
    /// offline past T the group would otherwise persist on the XMTP network
    /// with every peer still subscribed, and any message sent during that
    /// window syncs back onto phantom convo rows.
    ///
    /// Every leg is best-effort:
    /// - `leaveGroup` hitting libxmtp's 1 → 0 invariant (we're the last
    ///   member still present) is logged at info and swallowed; the zombie
    ///   outcome matches today's creator-side zombie.
    /// - `leaveGroup` against a group we're no longer a member of (creator's
    ///   `removeMembers` already landed) is logged at info and swallowed.
    /// - `denyConsent` always runs afterwards regardless of leave outcome as
    ///   belt-and-suspenders against re-sync if the leave failed for any
    ///   reason. It's idempotent when we've already left the group.
    func peerSelfLeaveExpiredConversation(conversationId: String) async {
        await runBoundedOp("peerLeaveExpiredGroup", logSuccess: true) { [operations] in
            do {
                try await operations.peerLeaveExpiredGroup(conversationId: conversationId)
            } catch {
                if Self.isBenignPeerLeaveError(error) {
                    Log.info("Peer self-leave skipped for \(conversationId): \(error.localizedDescription)")
                    return
                }
                throw error
            }
        }
        await runBoundedOp("denyConsent", logSuccess: true) { [operations] in
            try await operations.denyConsent(conversationId: conversationId)
        }
    }

    /// libxmtp surfaces MLS failures as FFI errors whose full message is only
    /// visible via `String(describing:)`. The two cases we treat as benign:
    ///
    /// - `LeaveCantProcessed` — "cannot leave a group that has only one
    ///   member" (we're the last peer still in; 1 → 0 invariant).
    /// - `NotFound::MlsGroup` — creator's `removeMembers` already landed
    ///   before our cleanup ran; we're no longer a member.
    private static func isBenignPeerLeaveError(_ error: any Error) -> Bool {
        let description = String(describing: error)
        return description.contains("LeaveCantProcessed")
            || description.contains("cannot leave a group that has only one member")
            || description.contains("NotFound::MlsGroup")
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
    /// full sweep. `logSuccess` toggles a success log line, set to true on
    /// the network-visible MLS legs so telemetry can confirm they completed.
    private func runBoundedOp(
        _ name: String,
        timeout: TimeInterval = 20,
        logSuccess: Bool = false,
        _ body: @escaping @Sendable () async throws -> Void
    ) async {
        do {
            try await withTimeout(seconds: timeout, operation: body)
            if logSuccess {
                Log.info("\(name) succeeded")
            }
        } catch {
            Log.error("\(name) failed: \(error.localizedDescription)")
        }
    }
}
