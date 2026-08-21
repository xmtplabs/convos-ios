import Foundation
@preconcurrency import XMTPiOS

/// Concrete `ProfilePublishSession` backed by the XMTP client and upload API.
/// Uploads and sends the self profile to a conversation, including the
/// best-effort second channel (writing the profile into group app-data) so
/// clients that read `ConversationProfile` rather than the `ProfileUpdate`
/// message still see the identity.
///
/// This is boundary code (it uses XMTP types directly, like the writers). It is
/// exercised only once the publisher is fed at the cutover; there is no
/// meaningful unit test - it is verified via integration / manual runs.
struct MessagingProfilePublishSession: ProfilePublishSession {
    private let sessionStateManager: any SessionStateManagerProtocol

    init(sessionStateManager: any SessionStateManagerProtocol) {
        self.sessionStateManager = sessionStateManager
    }

    func upload(_ data: Data, filename: String, contentType: String) async throws -> String {
        let inboxReady = try await sessionStateManager.waitForInboxReadyResult()
        return try await inboxReady.apiClient.uploadAttachment(
            data: data,
            filename: filename,
            contentType: contentType,
            acl: "public-read"
        )
    }

    func sendProfileUpdate(name: String?, metadata: ProfileMetadata?, avatar: PublishedAvatar?, conversationId: String) async throws {
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
        if let avatar {
            // A legacy encrypted avatar being re-advertised carries full crypto
            // and rides `encrypted_image`; a plain avatar (the write path now
            // only produces these) rides the plain `image` URL instead.
            if let salt = avatar.salt, let nonce = avatar.nonce, avatar.key != nil {
                var ref = EncryptedProfileImageRef()
                ref.url = avatar.url
                ref.salt = salt
                ref.nonce = nonce
                update.encryptedImage = ref
            } else {
                update.image = avatar.url
            }
        }
        if let resolvedMetadata {
            update.metadata = resolvedMetadata.asProtoMap
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
        ).with(metadata: resolvedMetadata)
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
