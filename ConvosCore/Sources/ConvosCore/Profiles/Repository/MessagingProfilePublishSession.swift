import Foundation
import GRDB
@preconcurrency import XMTPiOS

/// Concrete `ProfilePublishSession` backed by the XMTP client and upload API.
/// Mirrors the encrypt/upload/send path in `MyProfileWriter`, including the
/// best-effort second channel (writing the profile into group app-data) so
/// clients that read `ConversationProfile` rather than the `ProfileUpdate`
/// message still see the identity.
///
/// This is boundary code (it uses XMTP types directly, like the writers). It is
/// exercised only once the publisher is fed at the cutover; there is no
/// meaningful unit test - it is verified via integration / manual runs.
struct MessagingProfilePublishSession: ProfilePublishSession {
    private let sessionStateManager: any SessionStateManagerProtocol
    private let databaseReader: any DatabaseReader

    init(sessionStateManager: any SessionStateManagerProtocol, databaseReader: any DatabaseReader) {
        self.sessionStateManager = sessionStateManager
        self.databaseReader = databaseReader
    }

    func conversationIds() async throws -> [String] {
        try await databaseReader.read { db in
            try String.fetchAll(db, sql: "SELECT id FROM conversation")
        }
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

    func sendProfileUpdate(name: String?, avatar: PublishedAvatar?, conversationId: String) async throws {
        let inboxReady = try await sessionStateManager.waitForInboxReadyResult()
        guard let conversation = try await inboxReady.client.conversation(with: conversationId),
              case .group(let group) = conversation else {
            throw ProfilePublishSessionError.conversationNotFound(conversationId: conversationId)
        }

        var update = ProfileUpdate()
        if let name {
            update.name = name
        }
        if let avatar {
            var ref = EncryptedProfileImageRef()
            ref.url = avatar.url
            ref.salt = avatar.salt
            ref.nonce = avatar.nonce
            update.encryptedImage = ref
        }
        let encoded = try ProfileUpdateCodec().encode(content: update)
        _ = try await group.send(encodedContent: encoded)

        // Second channel: mirror into group app-data (best-effort). `updateProfile`
        // merges, so a nil avatar preserves the existing app-data image rather
        // than clearing it.
        let memberProfile = DBMemberProfile(
            conversationId: conversationId,
            inboxId: inboxReady.client.inboxId,
            name: name,
            avatar: avatar?.url,
            avatarSalt: avatar?.salt,
            avatarNonce: avatar?.nonce,
            avatarKey: avatar?.key
        )
        do {
            try await group.updateProfile(memberProfile)
        } catch {
            Log.warning("ProfilePublishSession app-data updateProfile failed (best-effort): \(error.localizedDescription)")
        }
    }
}

enum ProfilePublishSessionError: Error {
    case conversationNotFound(conversationId: String)
}
