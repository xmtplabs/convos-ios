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
    private let inboxStateManager: any InboxStateManagerProtocol
    private let metadataWriter: any ConversationMetadataWriterProtocol

    init(
        inboxStateManager: any InboxStateManagerProtocol,
        metadataWriter: any ConversationMetadataWriterProtocol
    ) {
        self.inboxStateManager = inboxStateManager
        self.metadataWriter = metadataWriter
    }

    func explodeConversation(conversationId: String, memberInboxIds: [String]) async throws {
        let expiresAt = Date()

        let (xmtpConversation, group) = try await findGroupConversation(conversationId: conversationId)

        Log.info("Sending ExplodeSettings message...")
        nonisolated(unsafe) let unsafeConversation = xmtpConversation
        try await withTimeout(seconds: 20) {
            try await unsafeConversation.sendExplode(expiresAt: expiresAt)
        }
        Log.info("ExplodeSettings message sent successfully")

        do {
            try await metadataWriter.updateExpiresAt(expiresAt, for: conversationId)
        } catch {
            Log.error("Failed updating local expiresAt after explosion: \(error.localizedDescription)")
        }

        do {
            try await metadataWriter.removeMembers(memberInboxIds, from: conversationId)
        } catch {
            Log.error("Failed removing local members after explosion: \(error.localizedDescription)")
        }

        do {
            try await group.updateConsentState(state: .denied)
            Log.info("Denied exploded conversation to prevent re-sync")
        } catch {
            Log.error("Failed denying consent after explosion: \(error.localizedDescription)")
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
        let inboxReady = try await inboxStateManager.waitForInboxReadyResult()
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
