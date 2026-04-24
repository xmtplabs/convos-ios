import ConvosAppData
import ConvosProfiles
import Foundation
import XMTPiOS

// swiftlint:disable:next orphaned_doc_comment
/// Boundary shim re-exposing the Convos custom-metadata API on the raw
/// `XMTPiOS.Group` type. The real engine lives in
/// `MessagingGroup+CustomMetadata.swift` and operates against the
/// `MessagingGroup` abstraction.
///
/// This file deliberately contains no business logic; every method delegates
/// into `ConversationCustomMetadataEngine`. It exists only so that legacy
/// call sites that still hand around `XMTPiOS.Group` (writers, state
/// machines, syncing, tests) keep compiling during the Stage-2 → Stage-4
/// migration. Once the abstraction-based adapter for `XMTPiOS.Group` lands
/// and all callers migrate to `any MessagingGroup`, this file can be deleted.

// MARK: - XMTPiOS.Group + CustomMetadata (shim)

extension XMTPiOS.Group {
    /// Engine bound to this group's sync `appData()` / async
    /// `updateAppData(appData:)`. `appData()` is synchronous on
    /// `XMTPiOS.Group`, so we wrap it in an `async` closure to satisfy the
    /// engine's signature.
    private var customMetadataEngine: ConversationCustomMetadataEngine {
        ConversationCustomMetadataEngine(
            id: id,
            readAppData: { try self.appData() },
            writeAppData: { newValue in try await self.updateAppData(appData: newValue) }
        )
    }

    // MARK: Reads

    var currentCustomMetadata: ConversationCustomMetadata {
        get throws {
            do {
                let currentAppData = try self.appData()
                return ConversationCustomMetadata.parseAppData(currentAppData)
            } catch {
                Log.error("Failed to read custom metadata: \(error)")
                return .init()
            }
        }
    }

    public var inviteTag: String {
        get throws {
            try currentCustomMetadata.tag
        }
    }

    public var expiresAt: Date? {
        get throws {
            let metadata = try currentCustomMetadata
            guard metadata.hasExpiresAtUnix else { return nil }
            return Date(timeIntervalSince1970: TimeInterval(metadata.expiresAtUnix))
        }
    }

    public var conversationEmoji: String? {
        get throws {
            let metadata = try currentCustomMetadata
            guard metadata.hasEmoji, !metadata.emoji.isEmpty else { return nil }
            return metadata.emoji
        }
    }

    public var imageEncryptionKey: Data? {
        get throws {
            let metadata = try currentCustomMetadata
            guard metadata.hasImageEncryptionKey else { return nil }
            return metadata.imageEncryptionKey
        }
    }

    public var encryptedGroupImage: EncryptedImageRef? {
        get throws {
            let metadata = try currentCustomMetadata
            guard metadata.hasEncryptedGroupImage,
                  metadata.encryptedGroupImage.isValid else {
                return nil
            }
            return metadata.encryptedGroupImage
        }
    }

    var memberProfiles: [DBMemberProfile] {
        get throws {
            try memberProfiles(withKey: imageEncryptionKey)
        }
    }

    func memberProfiles(withKey groupKey: Data?) throws -> [DBMemberProfile] {
        let customMetadata = try currentCustomMetadata
        return customMetadata.profiles.map { profile in
            let avatarUrl: String?
            let salt: Data?
            let nonce: Data?
            let key: Data?

            if profile.hasEncryptedImage, profile.encryptedImage.isValid {
                avatarUrl = profile.encryptedImage.url
                salt = profile.encryptedImage.salt
                nonce = profile.encryptedImage.nonce
                key = groupKey
            } else {
                avatarUrl = profile.hasImage ? profile.image : nil
                salt = nil
                nonce = nil
                key = nil
            }

            return .init(
                conversationId: id,
                inboxId: profile.inboxIdString,
                name: profile.hasName ? profile.name : nil,
                avatar: avatarUrl,
                avatarSalt: salt,
                avatarNonce: nonce,
                avatarKey: key
            )
        }
    }

    // MARK: Writes (delegated to the engine)

    public func ensureConversationEmoji(seed: String) async throws -> String {
        try await customMetadataEngine.ensureConversationEmoji(seed: seed)
    }

    public func updateExpiresAt(date: Date) async throws {
        try await customMetadataEngine.updateExpiresAt(date: date)
    }

    @discardableResult
    public func ensureImageEncryptionKey() async throws -> Data {
        try await customMetadataEngine.ensureImageEncryptionKey()
    }

    public func updateEncryptedGroupImage(_ encryptedRef: EncryptedImageRef) async throws {
        try await customMetadataEngine.updateEncryptedGroupImage(encryptedRef)
    }

    // This should only be done by the conversation creator
    // Updating the invite tag effectively expires all invites generated with that tag
    // The tag is used by the invitee to verify the conversation they've been added to
    // is the one that corresponds to the invite they are requesting to join
    public func ensureInviteTag() async throws {
        try await customMetadataEngine.ensureInviteTag()
    }

    /// Rotates the invite tag, invalidating all existing invites for this conversation.
    /// This is used when locking a conversation to ensure no outstanding invites can be used.
    public func rotateInviteTag() async throws {
        try await customMetadataEngine.rotateInviteTag()
    }

    public func restoreInviteTagIfMissing(_ expectedTag: String) async throws {
        try await customMetadataEngine.restoreInviteTagIfMissing(expectedTag)
    }

    func updateProfile(_ profile: DBMemberProfile) async throws {
        try await customMetadataEngine.updateProfile(profile)
    }

    func updateMetadata(_ metadata: ConversationCustomMetadata) async throws {
        try await customMetadataEngine.updateMetadata(metadata)
    }
}
