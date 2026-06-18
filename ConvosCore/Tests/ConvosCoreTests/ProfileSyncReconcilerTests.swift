@testable import ConvosCore
import Foundation
import GRDB
import Testing

/// Covers `ProfileSyncReconciler.fetchMismatchedConversationIds` - the
/// observation query that decides which conversations still need their global
/// profile re-published. The reconciler re-drives exactly these, so the gate
/// must converge (return empty once the published markers match the global
/// profile) and must ignore drafts and other members.
@Suite("ProfileSyncReconciler mismatch query", .serialized)
struct ProfileSyncReconcilerTests {
    private static let selfInboxId: String = "inbox-self"
    private static let otherInboxId: String = "inbox-other"

    private static func mismatched(_ reader: any DatabaseReader) throws -> [String] {
        try reader.read { db in
            try ProfileSyncReconciler.fetchMismatchedConversationIds(db: db, inboxId: selfInboxId)
        }
    }

    private static func seedConversation(db: Database, id: String) throws {
        try DBConversation(
            id: id,
            clientConversationId: "client-\(id)",
            inviteTag: "tag-\(id)",
            creatorId: selfInboxId,
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

    private static func seedGlobal(db: Database, name: String?, imageData: Data?, imageDigest: String?) throws {
        try DBMyProfile(
            inboxId: selfInboxId,
            name: name,
            imageData: imageData,
            imageAssetIdentifier: nil,
            imageContentDigest: imageDigest,
            metadata: nil,
            updatedAt: Date(timeIntervalSince1970: 2_000)
        ).save(db)
    }

    private static func seedSelfMember(
        db: Database,
        conversationId: String,
        publishedNameDigest: String?,
        publishedAvatarDigest: String?
    ) throws {
        try DBMember(inboxId: selfInboxId).save(db, onConflict: .ignore)
        try DBMemberProfile(
            conversationId: conversationId,
            inboxId: selfInboxId,
            name: nil,
            avatar: nil,
            publishedNameDigest: publishedNameDigest,
            publishedAvatarDigest: publishedAvatarDigest
        ).save(db)
    }

    @Test("name not yet published is a mismatch; matching digest converges")
    func nameGate() throws {
        let dbManager = MockDatabaseManager.makeTestDatabase()
        let nameDigest = MyProfileWriter.nameDigest("Alice")

        try dbManager.dbWriter.write { db in
            try Self.seedGlobal(db: db, name: "Alice", imageData: nil, imageDigest: nil)
            try Self.seedConversation(db: db, id: "c1")
            try Self.seedSelfMember(db: db, conversationId: "c1", publishedNameDigest: nil, publishedAvatarDigest: nil)
        }
        let beforeIds = try Self.mismatched(dbManager.dbReader)
        #expect(beforeIds == ["c1"])

        // Mark it published with the matching digest -> converges to empty.
        try dbManager.dbWriter.write { db in
            try Self.seedSelfMember(db: db, conversationId: "c1", publishedNameDigest: nameDigest, publishedAvatarDigest: nil)
        }
        let afterIds = try Self.mismatched(dbManager.dbReader)
        #expect(afterIds.isEmpty)
    }

    @Test("avatar present but unpublished is a mismatch")
    func avatarGate() throws {
        let dbManager = MockDatabaseManager.makeTestDatabase()
        let nameDigest = MyProfileWriter.nameDigest("Alice")
        try dbManager.dbWriter.write { db in
            try Self.seedGlobal(db: db, name: "Alice", imageData: Data([0x1, 0x2]), imageDigest: "X")
            try Self.seedConversation(db: db, id: "c1")
            try Self.seedSelfMember(db: db, conversationId: "c1", publishedNameDigest: nameDigest, publishedAvatarDigest: nil)
        }
        #expect(try Self.mismatched(dbManager.dbReader) == ["c1"])

        try dbManager.dbWriter.write { db in
            try Self.seedSelfMember(db: db, conversationId: "c1", publishedNameDigest: nameDigest, publishedAvatarDigest: "X")
        }
        #expect(try Self.mismatched(dbManager.dbReader).isEmpty)
    }

    @Test("not-rehydrated avatar (digest set, bytes absent) is not a mismatch")
    func notRehydratedAvatarIsNoMismatch() throws {
        let dbManager = MockDatabaseManager.makeTestDatabase()
        let nameDigest = MyProfileWriter.nameDigest("Alice")
        try dbManager.dbWriter.write { db in
            // Paired-device shape: digest present but no image bytes.
            try Self.seedGlobal(db: db, name: "Alice", imageData: nil, imageDigest: "X")
            try Self.seedConversation(db: db, id: "c1")
            try Self.seedSelfMember(db: db, conversationId: "c1", publishedNameDigest: nameDigest, publishedAvatarDigest: nil)
        }
        #expect(try Self.mismatched(dbManager.dbReader).isEmpty)
    }

    @Test("cleared global avatar requires un-publishing a previously published avatar")
    func clearedAvatarGate() throws {
        let dbManager = MockDatabaseManager.makeTestDatabase()
        let nameDigest = MyProfileWriter.nameDigest("Alice")
        try dbManager.dbWriter.write { db in
            try Self.seedGlobal(db: db, name: "Alice", imageData: nil, imageDigest: nil)
            try Self.seedConversation(db: db, id: "c1")
            try Self.seedSelfMember(db: db, conversationId: "c1", publishedNameDigest: nameDigest, publishedAvatarDigest: "X")
        }
        #expect(try Self.mismatched(dbManager.dbReader) == ["c1"])
    }

    @Test("drafts and other members are ignored")
    func ignoresDraftsAndOtherMembers() throws {
        let dbManager = MockDatabaseManager.makeTestDatabase()
        let draftId = DBConversation.generateDraftConversationId()
        try dbManager.dbWriter.write { db in
            try Self.seedGlobal(db: db, name: "Alice", imageData: nil, imageDigest: nil)
            // Draft conversation with an unpublished self member -> ignored.
            try Self.seedConversation(db: db, id: draftId)
            try Self.seedSelfMember(db: db, conversationId: draftId, publishedNameDigest: nil, publishedAvatarDigest: nil)
            // Another member's row in a real conversation -> ignored (not self).
            try Self.seedConversation(db: db, id: "c1")
            try DBMember(inboxId: Self.otherInboxId).save(db, onConflict: .ignore)
            try DBMemberProfile(conversationId: "c1", inboxId: Self.otherInboxId, name: nil, avatar: nil).save(db)
        }
        #expect(try Self.mismatched(dbManager.dbReader).isEmpty)
    }

    @Test("no global profile yields no targets")
    func noGlobalProfile() throws {
        let dbManager = MockDatabaseManager.makeTestDatabase()
        try dbManager.dbWriter.write { db in
            try Self.seedConversation(db: db, id: "c1")
            try Self.seedSelfMember(db: db, conversationId: "c1", publishedNameDigest: nil, publishedAvatarDigest: nil)
        }
        #expect(try Self.mismatched(dbManager.dbReader).isEmpty)
    }
}
