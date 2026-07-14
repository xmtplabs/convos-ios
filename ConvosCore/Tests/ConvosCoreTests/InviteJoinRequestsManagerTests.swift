@testable import ConvosCore
import ConvosInvites
import Foundation
import GRDB
import Testing

@Suite("InviteJoinRequestsManager Tests")
struct InviteJoinRequestsManagerTests {
    let now = Date(timeIntervalSince1970: 1_780_000_000)
    let day: TimeInterval = 24 * 60 * 60

    // MARK: - Post-join snapshot routing

    @Test("Accepted join re-publishes the joined conversation's snapshot")
    func acceptedTriggersSnapshot() {
        let result = JoinResult(
            conversationId: "group-1",
            joinerInboxId: "joiner-1",
            conversationName: "Group"
        )
        let outcome = JoinRequestDMOutcome.accepted(result, dmConversationId: "dm-1")
        #expect(InviteJoinRequestsManager.profileSnapshotConversationId(for: outcome) == "group-1")
    }

    @Test("Verified already-member result re-publishes the snapshot for its conversation")
    func verifiedAlreadyMemberTriggersSnapshot() {
        let outcome = JoinRequestDMOutcome.alreadyMember(
            dmConversationId: "dm-1",
            joinerInboxId: "joiner-1",
            verified: AlreadyMemberContext(conversationId: "group-1", profile: nil, metadata: nil)
        )
        #expect(InviteJoinRequestsManager.profileSnapshotConversationId(for: outcome) == "group-1")
    }

    @Test("Ledger-only already-member result does not re-publish a snapshot")
    func ledgerAlreadyMemberSkipsSnapshot() {
        let outcome = JoinRequestDMOutcome.alreadyMember(
            dmConversationId: "dm-1",
            joinerInboxId: "joiner-1",
            verified: nil
        )
        #expect(InviteJoinRequestsManager.profileSnapshotConversationId(for: outcome) == nil)
    }

    @Test("Non-joining outcomes never re-publish a snapshot")
    func nonJoiningOutcomesSkipSnapshot() {
        let benign = JoinRequestDMOutcome.benignFailure(
            dmConversationId: "dm-1",
            senderInboxId: "joiner-1",
            error: .addMemberFailed
        )
        let malicious = JoinRequestDMOutcome.malicious(
            dmConversationId: "dm-1",
            senderInboxId: "joiner-1",
            error: .invalidSignature
        )
        #expect(InviteJoinRequestsManager.profileSnapshotConversationId(for: benign) == nil)
        #expect(InviteJoinRequestsManager.profileSnapshotConversationId(for: malicious) == nil)
        #expect(InviteJoinRequestsManager.profileSnapshotConversationId(for: .noJoinRequest) == nil)
    }

    @Test("Nil cursor clamps to the 24h window instead of sweeping all history")
    func nilCursorClampsToWindow() {
        let effective = InviteJoinRequestsManager.effectiveCatchUpSince(since: nil, now: now)
        #expect(effective == now.addingTimeInterval(-day))
    }

    @Test("Recent cursor passes through unchanged")
    func recentCursorUnchanged() {
        let recent = now.addingTimeInterval(-300)
        let effective = InviteJoinRequestsManager.effectiveCatchUpSince(since: recent, now: now)
        #expect(effective == recent)
    }

    @Test("Cursor older than the window clamps to the window")
    func ancientCursorClamps() {
        let ancient = now.addingTimeInterval(-90 * day)
        let effective = InviteJoinRequestsManager.effectiveCatchUpSince(since: ancient, now: now)
        #expect(effective == now.addingTimeInterval(-day))
    }

    @Test("Cursor exactly at the window boundary is preserved")
    func boundaryCursorPreserved() {
        let boundary = now.addingTimeInterval(-day)
        let effective = InviteJoinRequestsManager.effectiveCatchUpSince(since: boundary, now: now)
        #expect(effective == boundary)
    }
}

@Suite("InviteJoinRequestsManager profile persistence", .serialized)
struct InviteJoinRequestsManagerPersistenceTests {
    private func makeManager(_ dbManager: MockDatabaseManager) -> InviteJoinRequestsManager {
        InviteJoinRequestsManager(
            identityStore: MockKeychainIdentityStore(),
            databaseWriter: dbManager.dbWriter
        )
    }

    private func seedConversation(_ db: Database, id: String) throws {
        let creatorInboxId = "creator-\(id)"
        try DBMember(inboxId: creatorInboxId).save(db, onConflict: .ignore)
        try DBConversation(
            id: id,
            clientConversationId: id,
            inviteTag: "tag-\(id)",
            creatorId: creatorInboxId,
            kind: .group,
            consent: .allowed,
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

    @Test("Empty metadata and no profile fields does not blank an existing member row")
    func emptyMetadataDoesNotBlankExistingRow() async throws {
        let dbManager = MockDatabaseManager.makeTestDatabase()
        let manager = makeManager(dbManager)

        let conversationId = "convo-persist-1"
        let joinerInboxId = "joiner-persist-1"

        try await dbManager.dbWriter.write { db in
            try self.seedConversation(db, id: conversationId)
            try DBMember(inboxId: joinerInboxId).save(db, onConflict: .ignore)
            try DBMemberProfile(
                conversationId: conversationId,
                inboxId: joinerInboxId,
                name: "Good Name",
                avatar: nil,
                memberKind: nil,
                metadata: ["k": .string("v")]
            ).insert(db)
        }

        // All-nil profile with an empty (but non-nil) metadata dictionary must
        // be a no-op, not an overwrite that blanks the existing row.
        await manager.persistJoinerProfile(
            joinerInboxId: joinerInboxId,
            conversationId: conversationId,
            profile: nil,
            metadata: [:]
        )

        let afterEmpty = try await dbManager.dbReader.read { db in
            try DBMemberProfile.fetchOne(db, conversationId: conversationId, inboxId: joinerInboxId)
        }
        #expect(afterEmpty?.name == "Good Name", "Empty-metadata persist must not blank an existing row")
        #expect(afterEmpty?.metadata?["k"]?.stringValue == "v")

        // A populated profile still persists as before.
        await manager.persistJoinerProfile(
            joinerInboxId: joinerInboxId,
            conversationId: conversationId,
            profile: JoinRequestProfile(name: "New Name", imageURL: nil, memberKind: nil),
            metadata: nil
        )

        let afterReal = try await dbManager.dbReader.read { db in
            try DBMemberProfile.fetchOne(db, conversationId: conversationId, inboxId: joinerInboxId)
        }
        #expect(afterReal?.name == "New Name", "A populated profile must still persist")
    }

    @Test("A joiner's profile is written to the canonical tables, so they never render as Somebody")
    func persistsCanonicalProfile() async throws {
        let dbManager = MockDatabaseManager.makeTestDatabase()
        let manager = makeManager(dbManager)

        let conversationId = "convo-canonical-1"
        let joinerInboxId = "joiner-canonical-1"
        try await dbManager.dbWriter.write { db in
            try self.seedConversation(db, id: conversationId)
        }

        await manager.persistJoinerProfile(
            joinerInboxId: joinerInboxId,
            conversationId: conversationId,
            profile: JoinRequestProfile(name: "Joiner Jane", imageURL: "https://img/plain.jpg", memberKind: nil),
            metadata: ["team": "convos"]
        )

        // Rendering reads DBProfile; the legacy row alone leaves the joiner as
        // "Somebody" until their first ProfileUpdate.
        let canonical = try await dbManager.dbReader.read { db in
            try DBProfile.fetchOne(db, inboxId: joinerInboxId)
        }
        #expect(canonical?.name == "Joiner Jane")
        #expect(canonical?.profileSource == .profileSnapshot)
        #expect(canonical?.metadata?["team"] == .string("convos"))
        // The join request's plain image URL cannot become a canonical avatar
        // slot (slots are group-encrypted).
        let slot = try await dbManager.dbReader.read { db in
            try DBProfileAvatar.fetchOne(db, inboxId: joinerInboxId, conversationId: conversationId)
        }
        #expect(slot == nil)
    }

    @Test("A replayed join request cannot beat the joiner's own newer ProfileUpdate")
    func joinRequestReplayDoesNotBeatProfileUpdate() async throws {
        let dbManager = MockDatabaseManager.makeTestDatabase()
        let manager = makeManager(dbManager)

        let conversationId = "convo-canonical-2"
        let joinerInboxId = "joiner-canonical-2"
        try await dbManager.dbWriter.write { db in
            try self.seedConversation(db, id: conversationId)
            // The joiner's real ProfileUpdate already arrived (older wall
            // clock than the replay's Date() stamp, higher source).
            try DBProfile(
                inboxId: joinerInboxId,
                name: "Current Name",
                profileSource: .profileUpdate,
                updatedAt: Date(timeIntervalSince1970: 1_000)
            ).save(db)
        }

        await manager.persistJoinerProfile(
            joinerInboxId: joinerInboxId,
            conversationId: conversationId,
            profile: JoinRequestProfile(name: "Stale Join Name", imageURL: nil, memberKind: nil),
            metadata: nil
        )

        let canonical = try await dbManager.dbReader.read { db in
            try DBProfile.fetchOne(db, inboxId: joinerInboxId)
        }
        #expect(canonical?.name == "Current Name")
        #expect(canonical?.profileSource == .profileUpdate)
    }
}
