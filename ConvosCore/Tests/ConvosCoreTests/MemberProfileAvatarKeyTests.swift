@testable import ConvosCore
import Foundation
import GRDB
import Testing

/// Covers the fix for blank avatars caused by persisting an encrypted-avatar
/// reference without its decryption key: the `applyingEncryptedAvatar` guard
/// (never write a keyless avatar) and the `backfillKeylessMemberAvatars` repair
/// (stamp the group key onto pre-existing keyless rows once it's known).
@Suite("Member profile avatar key handling", .serialized)
struct MemberProfileAvatarKeyTests {
    private static func base() -> DBMemberProfile {
        DBMemberProfile(conversationId: "c1", inboxId: "inbox-1", name: "Alice", avatar: nil)
    }

    // MARK: - applyingEncryptedAvatar guard

    @Test("nil key leaves the existing avatar untouched (no keyless write)")
    func nilKeySkips() {
        let existing = Self.base().with(
            avatar: "https://example.com/old.enc",
            salt: Data(repeating: 0x01, count: 32),
            nonce: Data(repeating: 0x02, count: 12),
            key: Data(repeating: 0x03, count: 32)
        )
        let result = existing.applyingEncryptedAvatar(
            url: "https://example.com/new.enc",
            salt: Data(repeating: 0x10, count: 32),
            nonce: Data(repeating: 0x11, count: 12),
            resolvedKey: nil
        )
        // Unchanged: the prior (decryptable) avatar is preserved rather than
        // replaced by a keyless one.
        #expect(result.avatar == "https://example.com/old.enc")
        #expect(result.avatarKey == Data(repeating: 0x03, count: 32))
    }

    @Test("resolved key applies the new encrypted avatar")
    func presentKeyApplies() {
        let result = Self.base().applyingEncryptedAvatar(
            url: "https://example.com/new.enc",
            salt: Data(repeating: 0x10, count: 32),
            nonce: Data(repeating: 0x11, count: 12),
            resolvedKey: Data(repeating: 0x12, count: 32)
        )
        #expect(result.avatar == "https://example.com/new.enc")
        #expect(result.avatarKey == Data(repeating: 0x12, count: 32))
        #expect(result.hasValidEncryptedAvatar)
    }

    // MARK: - backfillKeylessMemberAvatars repair

    private static func seedConversation(db: Database, id: String) throws {
        try DBConversation(
            id: id,
            clientConversationId: "client-\(id)",
            inviteTag: "tag-\(id)",
            creatorId: "inbox-self",
            kind: .group,
            consent: .allowed,
            createdAt: Date(timeIntervalSince1970: 1_000),
            name: nil,
            description: nil,
            imageURLString: nil,
            publicImageURLString: nil,
            includeInfoInPublicPreview: false,
            expiresAt: nil,
            debugInfo: .empty,
            isLocked: false,
            imageSalt: nil,
            imageNonce: nil,
            imageEncryptionKey: nil,
            conversationEmoji: nil,
            imageLastRenewed: nil,
            isUnused: false,
            hasHadVerifiedAgent: false
        ).insert(db, onConflict: .ignore)
    }

    private static func seedMember(db: Database, inboxId: String, _ profile: DBMemberProfile) throws {
        try DBMember(inboxId: inboxId).save(db, onConflict: .ignore)
        try profile.save(db)
    }

    @Test("backfill stamps the key onto keyless avatars, leaves others alone")
    func backfillRepairsKeylessRows() throws {
        let dbManager = MockDatabaseManager.makeTestDatabase()
        let groupKey = Data(repeating: 0xAB, count: 32)
        let salt = Data(repeating: 0x01, count: 32)
        let nonce = Data(repeating: 0x02, count: 12)

        try dbManager.dbWriter.write { db in
            try Self.seedConversation(db: db, id: "c1")
            // Keyless avatar (the bug): url + salt + nonce, no key.
            try Self.seedMember(db: db, inboxId: "keyless", DBMemberProfile(
                conversationId: "c1", inboxId: "keyless", name: nil,
                avatar: "https://example.com/a.enc", avatarSalt: salt, avatarNonce: nonce, avatarKey: nil
            ))
            // Already-keyed avatar: must not be touched.
            try Self.seedMember(db: db, inboxId: "keyed", DBMemberProfile(
                conversationId: "c1", inboxId: "keyed", name: nil,
                avatar: "https://example.com/b.enc", avatarSalt: salt, avatarNonce: nonce,
                avatarKey: Data(repeating: 0xCD, count: 32)
            ))
            // No avatar at all: must not gain a phantom key.
            try Self.seedMember(db: db, inboxId: "noavatar", DBMemberProfile(
                conversationId: "c1", inboxId: "noavatar", name: "Bob", avatar: nil
            ))

            try ConversationWriter.backfillKeylessMemberAvatars(conversationId: "c1", key: groupKey, in: db)
        }

        try dbManager.dbReader.read { db in
            let keyless = try DBMemberProfile.fetchOne(db, conversationId: "c1", inboxId: "keyless")
            #expect(keyless?.avatarKey == groupKey)
            #expect(keyless?.hasValidEncryptedAvatar == true)

            let keyed = try DBMemberProfile.fetchOne(db, conversationId: "c1", inboxId: "keyed")
            #expect(keyed?.avatarKey == Data(repeating: 0xCD, count: 32))

            let noavatar = try DBMemberProfile.fetchOne(db, conversationId: "c1", inboxId: "noavatar")
            #expect(noavatar?.avatarKey == nil)
        }
    }
}
