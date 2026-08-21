import Foundation
@preconcurrency import XMTPiOS

/// Concrete `ProfilePublishSession` backed by the XMTP client. Sends the self
/// profile to a conversation as a single message carrying the backend's avatar
/// URL - no per-conversation encryption, no upload, and no app-data commit.
///
/// This is boundary code (it uses XMTP types directly, like the writers). It is
/// exercised only once the publisher is fed at the cutover; there is no
/// meaningful unit test - it is verified via integration / manual runs.
struct MessagingProfilePublishSession: ProfilePublishSession {
    private let sessionStateManager: any SessionStateManagerProtocol

    init(sessionStateManager: any SessionStateManagerProtocol) {
        self.sessionStateManager = sessionStateManager
    }

    func imageKey(conversationId: String) async throws -> Data? {
        let inboxReady = try await sessionStateManager.waitForInboxReadyResult()
        guard let conversation = try await inboxReady.client.conversation(with: conversationId),
              case .group(let group) = conversation else {
            return nil
        }
        return try await group.ensureImageEncryptionKey()
    }

    func encrypt(_ plaintext: Data, groupKey: Data) throws -> EncryptedAvatarPayload {
        let payload = try ImageEncryption.encrypt(imageData: plaintext, groupKey: groupKey)
        return EncryptedAvatarPayload(ciphertext: payload.ciphertext, salt: payload.salt, nonce: payload.nonce)
    }

    func upload(_ ciphertext: Data, filename: String) async throws -> String {
        let inboxReady = try await sessionStateManager.waitForInboxReadyResult()
        return try await inboxReady.apiClient.uploadAttachment(
            data: ciphertext,
            filename: filename,
            contentType: "application/octet-stream",
            acl: "public-read"
        )
    }

    func sendProfileUpdate(
        name: String?,
        metadata: ProfileMetadata?,
        avatarUrl: String?,
        version: Int?,
        conversationId: String
    ) async throws {
        let inboxReady = try await sessionStateManager.waitForInboxReadyResult()
        guard let conversation = try await inboxReady.client.conversation(with: conversationId),
              case .group(let group) = conversation else {
            throw ProfilePublishSessionError.conversationNotFound(conversationId: conversationId)
        }

        let resolvedMetadata: ProfileMetadata? = (metadata?.isEmpty ?? true) ? nil : metadata

        var update = ProfileUpdate()
        if let name {
            update.name = name
        }
        if let avatarUrl {
            update.avatarURL = avatarUrl
        }
        if let version {
            update.version = UInt64(max(0, version))
        }
        if let resolvedMetadata {
            update.metadata = resolvedMetadata.asProtoMap
        }
        let encoded = try ProfileUpdateCodec().encode(content: update)
        _ = try await group.send(encodedContent: encoded)

        // No second channel. This used to mirror the profile into group
        // app-data as well, which cost an MLS commit per conversation on every
        // profile change. The backend is the durable copy now, and a client
        // that misses this message resolves the sender from it instead.
    }
}

enum ProfilePublishSessionError: Error {
    case conversationNotFound(conversationId: String)
}
