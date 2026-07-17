@testable import ConvosCore
import Foundation
import GRDB
import Testing

/// Coverage for `ConversationWriter.applyAppDataProfile`: app-data-sourced member
/// profiles are merged into the canonical `profile` / `profileAvatar` tables at
/// the `.appData` source, so a member known only from group app-data renders
/// instead of showing as "Somebody" - without ever overriding a higher-source
/// value.
@Suite("ConversationWriter app-data profile fill")
struct ConversationWriterAppDataProfileTests {
    private let salt = Data(repeating: 1, count: 32)
    private let nonce = Data(repeating: 2, count: 12)
    private let key = Data(repeating: 3, count: 32)

    @Test("fills canonical identity and avatar when empty")
    func fillsWhenEmpty() async throws {
        let queue = try ProfileStoreTestSupport.makeQueue(conversations: ["c1"])
        try await queue.write { db in
            try ConversationWriter.applyAppDataProfile(
                db: db,
                conversationId: "c1",
                profile: DBMemberProfile(
                    conversationId: "c1", inboxId: "alice", name: "Alice",
                    avatar: "u", avatarSalt: salt, avatarNonce: nonce, avatarKey: key
                ),
                selfInboxId: "me"
            )
        }

        let identity = try await queue.read { db in try DBProfile.fetchOne(db, inboxId: "alice") }
        let avatar = try await queue.read { db in try DBProfileAvatar.fetchOne(db, inboxId: "alice", conversationId: "c1") }
        #expect(identity?.name == "Alice")
        #expect(identity?.profileSource == .appData)
        #expect(avatar?.url == "u")
        #expect(avatar?.profileSource == .appData)
    }

    @Test("does not override a subject-authored profileUpdate name")
    func doesNotOverrideUpdate() async throws {
        let queue = try ProfileStoreTestSupport.makeQueue(conversations: ["c1"])
        try await queue.write { db in
            try DBProfile(inboxId: "alice", name: "Real", profileSource: .profileUpdate, updatedAt: Date(timeIntervalSince1970: 100)).save(db)
            try ConversationWriter.applyAppDataProfile(
                db: db,
                conversationId: "c1",
                profile: DBMemberProfile(conversationId: "c1", inboxId: "alice", name: "AppData", avatar: nil),
                selfInboxId: "me"
            )
        }

        let identity = try await queue.read { db in try DBProfile.fetchOne(db, inboxId: "alice") }
        #expect(identity?.name == "Real")
        #expect(identity?.profileSource == .profileUpdate)
    }

    @Test("fills a blank name left by a higher source, keeping that source")
    func fillsBlankFromHigherSource() async throws {
        let queue = try ProfileStoreTestSupport.makeQueue(conversations: ["c1"])
        try await queue.write { db in
            try DBProfile(inboxId: "alice", name: nil, profileSource: .profileUpdate, updatedAt: Date(timeIntervalSince1970: 100)).save(db)
            try ConversationWriter.applyAppDataProfile(
                db: db,
                conversationId: "c1",
                profile: DBMemberProfile(conversationId: "c1", inboxId: "alice", name: "AppData", avatar: nil),
                selfInboxId: "me"
            )
        }

        let identity = try await queue.read { db in try DBProfile.fetchOne(db, inboxId: "alice") }
        #expect(identity?.name == "AppData")
        // Provenance stays with the higher source; only the blank field was filled.
        #expect(identity?.profileSource == .profileUpdate)
    }

    @Test("skips the current user")
    func skipsSelf() async throws {
        let queue = try ProfileStoreTestSupport.makeQueue(conversations: ["c1"])
        try await queue.write { db in
            try ConversationWriter.applyAppDataProfile(
                db: db,
                conversationId: "c1",
                profile: DBMemberProfile(conversationId: "c1", inboxId: "me", name: "Me", avatar: nil),
                selfInboxId: "me"
            )
        }

        let identity = try await queue.read { db in try DBProfile.fetchOne(db, inboxId: "me") }
        #expect(identity == nil)
    }

    @Test("without a valid image does not clear an existing avatar")
    func doesNotClearAvatar() async throws {
        let queue = try ProfileStoreTestSupport.makeQueue(conversations: ["c1"])
        try await queue.write { db in
            try DBProfileAvatar(
                inboxId: "alice", conversationId: "c1", url: "old", salt: salt, nonce: nonce,
                encryptionKey: key, profileSource: .profileUpdate, updatedAt: Date(timeIntervalSince1970: 100)
            ).save(db)
            try ConversationWriter.applyAppDataProfile(
                db: db,
                conversationId: "c1",
                profile: DBMemberProfile(conversationId: "c1", inboxId: "alice", name: "Alice", avatar: nil),
                selfInboxId: "me"
            )
        }

        let avatar = try await queue.read { db in try DBProfileAvatar.fetchOne(db, inboxId: "alice", conversationId: "c1") }
        #expect(avatar?.url == "old")
    }
}
