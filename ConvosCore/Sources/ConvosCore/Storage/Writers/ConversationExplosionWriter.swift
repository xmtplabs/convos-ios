import Foundation
@preconcurrency import XMTPiOS

public protocol ConversationExplosionWriterProtocol: Sendable {
    func explodeConversation(conversationId: String, memberInboxIds: [String]) async throws
    func scheduleExplosion(conversationId: String, expiresAt: Date) async throws
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

final class ConversationExplosionWriter: ConversationExplosionWriterProtocol, @unchecked Sendable {
    private let sessionStateManager: any SessionStateManagerProtocol
    private let metadataWriter: any ConversationMetadataWriterProtocol

    init(
        sessionStateManager: any SessionStateManagerProtocol,
        metadataWriter: any ConversationMetadataWriterProtocol
    ) {
        self.sessionStateManager = sessionStateManager
        self.metadataWriter = metadataWriter
    }

    func explodeConversation(conversationId: String, memberInboxIds: [String]) async throws {
        let expiresAt = Date()

        let (xmtpConversation, group) = try await findGroupConversation(conversationId: conversationId)

        // Step 1: broadcast the explode-now message so every other member gets the
        // `conversationExpired` signal even if they don't process the subsequent
        // member-removal event in time.
        Log.info("Sending ExplodeSettings message...")
        nonisolated(unsafe) let unsafeConversation = xmtpConversation
        try await withTimeout(seconds: 20) {
            try await unsafeConversation.sendExplode(expiresAt: expiresAt)
        }
        Log.info("ExplodeSettings message sent successfully")
        QAEvent.emit(.conversation, "exploded", ["id": conversationId])

        // Step 2: set the local expiresAt so the sender's own UI hides the
        // conversation immediately. ConversationsRepository filters on
        // `expiresAt > Date()`, so a past value is the soft-delete trigger.
        do {
            try await metadataWriter.updateExpiresAt(expiresAt, for: conversationId)
        } catch {
            Log.error("Failed updating local expiresAt after explosion: \(error.localizedDescription)")
        }

        // Step 3: remove every other member from the MLS group. This emits
        // GroupUpdated removal events that other clients pick up even if they
        // missed the ExplodeSettings message (e.g. offline at send time).
        do {
            try await metadataWriter.removeMembers(memberInboxIds, from: conversationId)
        } catch {
            Log.error("Failed removing members during explosion: \(error.localizedDescription)")
        }

        // Step 4: creator leaves the group. In the per-conversation-identity era
        // this step didn't exist — the whole inbox was destroyed. With a single
        // shared inbox we can't destroy keys (they secure every other conversation),
        // so the cleanest exit is an explicit self-remove via `leaveGroup()`. The
        // XMTP SDK sends the MLS commit that takes us out of the group. `updateConsentState(.denied)`
        // was used pre-C9 as a belt-and-suspenders to keep the conversation from
        // re-syncing — it's now redundant with `leaveGroup()` (we're out of the
        // group so there's nothing left to sync), but preserving it as a no-op
        // guard in case the leave operation is interrupted.
        do {
            try await group.leaveGroup()
            Log.info("Creator left exploded group: \(conversationId)")
        } catch {
            Log.error("Failed leaving group after explosion: \(error.localizedDescription). Falling back to denied consent.")
            do {
                try await group.updateConsentState(state: .denied)
            } catch {
                Log.error("Also failed denying consent: \(error.localizedDescription)")
            }
        }
    }

    func scheduleExplosion(conversationId: String, expiresAt: Date) async throws {
        let (xmtpConversation, _) = try await findGroupConversation(conversationId: conversationId)

        Log.info("Scheduling explosion for \(expiresAt)...")
        nonisolated(unsafe) let unsafeConversation = xmtpConversation
        try await withTimeout(seconds: 20) {
            try await unsafeConversation.sendExplode(expiresAt: expiresAt)
        }
        Log.info("Scheduled explosion message sent successfully for \(expiresAt)")

        do {
            try await metadataWriter.updateExpiresAt(expiresAt, for: conversationId)
        } catch {
            Log.error("Failed to persist expiresAt locally: \(error.localizedDescription)")
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
