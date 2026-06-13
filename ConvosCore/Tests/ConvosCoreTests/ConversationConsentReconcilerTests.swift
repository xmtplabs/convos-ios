@testable import ConvosCore
import Foundation
import GRDB
import Testing

/// Coverage for `ConversationConsentReconciler.fetchMismatchedTargets` -
/// the query that drives the contact-state visibility transitions
/// (promotion of `.unknown`, demotion on block) by comparing a
/// conversation's stored consent against its creator's contact-block state.
@Suite("ConversationConsentReconciler Tests", .serialized)
struct ConversationConsentReconcilerTests {
    private static let selfInboxId: String = "inbox-self"

    @Test("Non-blocked contact: .unknown is promoted, .denied (user-deleted) is left alone")
    func testPromotesUnknownButNotDeniedFromNonBlockedContact() throws {
        let dbManager = MockDatabaseManager.makeTestDatabase()
        try dbManager.dbWriter.write { db in
            try Self.seedContact(db: db, inboxId: "contact-a", blockedAt: nil)
            try Self.seedConversation(db: db, id: "convo-unknown", creatorId: "contact-a", consent: .unknown)
            // The user deleted this one (delete sets .denied); the creator is
            // a non-blocked contact. The reconciler must NOT resurrect it.
            try Self.seedConversation(db: db, id: "convo-denied", creatorId: "contact-a", consent: .denied)
        }

        let targets = try dbManager.dbReader.read { db in
            try ConversationConsentReconciler.fetchMismatchedTargets(db: db)
        }

        #expect(targets == [.init(conversationId: "convo-unknown", consent: .allowed)])
    }

    @Test("Blocked contact with non-denied consent is demoted to .denied")
    func testDemotesAllowedFromBlockedContact() throws {
        let dbManager = MockDatabaseManager.makeTestDatabase()
        try dbManager.dbWriter.write { db in
            try Self.seedContact(db: db, inboxId: "contact-b", blockedAt: Date())
            try Self.seedConversation(db: db, id: "convo-allowed", creatorId: "contact-b", consent: .allowed)
        }

        let targets = try dbManager.dbReader.read { db in
            try ConversationConsentReconciler.fetchMismatchedTargets(db: db)
        }

        #expect(targets == [.init(conversationId: "convo-allowed", consent: .denied)])
    }

    @Test("Conversations already matching their creator's contact state are left alone")
    func testNoOpWhenConsentAlreadyMatches() throws {
        let dbManager = MockDatabaseManager.makeTestDatabase()
        try dbManager.dbWriter.write { db in
            try Self.seedContact(db: db, inboxId: "contact-ok", blockedAt: nil)
            try Self.seedContact(db: db, inboxId: "contact-blocked", blockedAt: Date())
            try Self.seedConversation(db: db, id: "convo-ok", creatorId: "contact-ok", consent: .allowed)
            try Self.seedConversation(db: db, id: "convo-blocked", creatorId: "contact-blocked", consent: .denied)
        }

        let targets = try dbManager.dbReader.read { db in
            try ConversationConsentReconciler.fetchMismatchedTargets(db: db)
        }

        #expect(targets.isEmpty)
    }

    @Test("Conversations from non-contacts are never touched, whatever their consent")
    func testLeavesNonContactConversationsAlone() throws {
        let dbManager = MockDatabaseManager.makeTestDatabase()
        try dbManager.dbWriter.write { db in
            // No contact rows for these creators: an unsolicited stranger
            // (.unknown) and a conversation the local user joined (.allowed).
            try Self.seedConversation(db: db, id: "convo-stranger", creatorId: "stranger", consent: .unknown)
            try Self.seedConversation(db: db, id: "convo-joined", creatorId: "host", consent: .allowed)
        }

        let targets = try dbManager.dbReader.read { db in
            try ConversationConsentReconciler.fetchMismatchedTargets(db: db)
        }

        #expect(targets.isEmpty)
    }

    private static func seedContact(db: Database, inboxId: String, blockedAt: Date?) throws {
        try DBContact(
            inboxId: inboxId,
            addedAt: Date(),
            addedViaConversationId: nil,
            displayName: nil,
            avatarURL: nil,
            avatarSalt: nil,
            avatarNonce: nil,
            avatarKey: nil,
            profileUpdatedAt: Date(),
            blockedAt: blockedAt,
            agentVerification: nil
        ).insert(db)
    }

    private static func seedConversation(
        db: Database,
        id: String,
        creatorId: String,
        consent: Consent
    ) throws {
        try DBMember(inboxId: creatorId).save(db, onConflict: .ignore)
        try DBConversation(
            id: id,
            clientConversationId: "client-\(id)",
            inviteTag: "tag-\(id)",
            creatorId: creatorId,
            kind: .group,
            consent: consent,
            createdAt: Date(),
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
        ).insert(db)
    }
}
