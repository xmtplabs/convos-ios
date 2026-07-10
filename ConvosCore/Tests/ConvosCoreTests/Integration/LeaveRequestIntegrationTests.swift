@testable import ConvosCore
import Foundation
import GRDB
import Testing
@preconcurrency import XMTPiOS

/// Integration coverage for the self-leave signal against a local XMTP node
/// (`./dev/up`). `leaveGroup()` publishes a leave-request message rather than
/// removing the member directly; the remove-commit is finalized later by an
/// authorized client. These tests pin the protocol behavior the departure
/// pipeline is built on: the leave-request reaches the other members with
/// normal message latency, our ingest maps it to a self-leave membership
/// update, and the MLS roster still lists the leaver until finalization.
@Suite("Leave request Integration Tests", .serialized)
struct LeaveRequestIntegrationTests {
    private func createClient() async throws -> Client {
        var keyBytes = [UInt8](repeating: 0, count: 32)
        _ = SecRandomCopyBytes(kSecRandomDefault, 32, &keyBytes)
        let dbKey = Data(keyBytes)
        let tmpDir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
        let options = ClientOptions(
            api: .init(env: .local, appVersion: "convos-tests/1.0.0"),
            codecs: [
                TextCodec(),
                GroupUpdatedCodec(),
                LeaveRequestCodec(),
            ],
            dbEncryptionKey: dbKey,
            dbDirectory: tmpDir.path
        )
        return try await Client.create(
            account: try PrivateKey.generate(),
            options: options
        )
    }

    @Test("leaveGroup publishes a leave-request other members ingest as a self-leave update")
    func leaveRequestReachesOtherMembers() async throws {
        let creatorClient = try await createClient()
        let leaverClient = try await createClient()
        defer {
            try? creatorClient.deleteLocalDatabase()
            try? leaverClient.deleteLocalDatabase()
        }

        let group = try await creatorClient.conversations.newGroup(with: [leaverClient.inboxId])

        _ = try await leaverClient.conversations.syncAllConversations(consentStates: nil)
        let leaverConversation = try await leaverClient.conversations.findConversation(conversationId: group.id)
        guard case .group(let leaverGroup) = try #require(leaverConversation) else {
            Issue.record("Leaver's conversation is not a group")
            return
        }

        // The leaver is a regular member (the creator holds super admin), so
        // the protocol accepts the self-leave.
        try await leaverGroup.leaveGroup()

        // The leaver's own client can't commit its own removal: it stays in
        // the roster in a pending-remove state until an authorized client
        // finalizes the commit.
        try await leaverGroup.sync()
        #expect(try leaverGroup.membershipState == .pendingRemove)
        let leaverRoster = try await leaverGroup.members.map(\.inboxId)
        #expect(leaverRoster.contains(leaverClient.inboxId))

        // The creator receives the leave-request as an ordinary message.
        try await group.sync()
        let messages = try await group.messages()
        let leaveRequest = try #require(
            messages.first { (try? $0.encodedContent.type) == ContentTypeLeaveRequest },
            "Creator should receive the leave-request message"
        )
        #expect(leaveRequest.senderInboxId == leaverClient.inboxId)

        // Ingest maps it to a membership update naming the sender as both
        // initiator and removed member -- the self-leave shape the transcript
        // renders as "<name> left" and the member-list drop keys off.
        let dbMessage = try leaveRequest.dbRepresentation()
        #expect(dbMessage.contentType == .update)
        #expect(dbMessage.update?.initiatedByInboxId == leaverClient.inboxId)
        #expect(dbMessage.update?.removedInboxIds == [leaverClient.inboxId])
        #expect(dbMessage.update?.addedInboxIds.isEmpty == true)
    }

    /// The user-observed critical scenario: a two-member group whose creator
    /// (sole super admin) leaves via the writer's promote -> demote -> leave
    /// order. The remaining member must keep the conversation, see the "left"
    /// update, and hold the transferred super admin role. This drives the real
    /// ingest path (IncomingMessageWriter + departure reconciliation) against
    /// the messages the remaining member's client actually receives.
    @Test("creator leaving a two-member group leaves the other member promoted with the conversation intact")
    func creatorLeaveKeepsConversationForRemainingMember() async throws {
        let creatorClient = try await createClient()
        let memberClient = try await createClient()
        defer {
            try? creatorClient.deleteLocalDatabase()
            try? memberClient.deleteLocalDatabase()
        }

        let creatorGroup = try await creatorClient.conversations.newGroup(with: [memberClient.inboxId])

        _ = try await memberClient.conversations.syncAllConversations(consentStates: nil)
        let memberConversation = try await memberClient.conversations.findConversation(conversationId: creatorGroup.id)
        guard case .group(let memberGroup) = try #require(memberConversation) else {
            Issue.record("Remaining member's conversation is not a group")
            return
        }
        let membershipStateBeforeLeave = try memberGroup.membershipState

        // The writer's operation order for a sole-super-admin leaver.
        try await creatorGroup.addSuperAdmin(inboxId: memberClient.inboxId)
        try await creatorGroup.removeSuperAdmin(inboxId: creatorClient.inboxId)
        try await creatorGroup.leaveGroup()

        // The remaining member's client processes the commits and the
        // leave-request; as the new super admin it may also finalize the
        // creator's removal.
        try await memberGroup.sync()
        _ = try await memberGroup.members

        // Promotion is visible on the remaining member's device.
        #expect(try memberGroup.listSuperAdmins().contains(memberClient.inboxId))
        // The remaining member's own membership is untouched by the creator's
        // leave (a raw SDK client that never consented stays `.pending`; it
        // must never flip to `.pendingRemove`).
        #expect(try memberGroup.membershipState == membershipStateBeforeLeave)
        #expect(try memberGroup.isActive())

        // Drive the real ingest path with everything the member received.
        let dbManager = MockDatabaseManager.makeTestDatabase()
        let conversationId = memberGroup.id
        try await dbManager.dbWriter.write { db in
            try Self.seedConversation(
                db: db,
                id: conversationId,
                currentInboxId: memberClient.inboxId,
                otherInboxId: creatorClient.inboxId
            )
        }

        let dbConversation = try await dbManager.dbWriter.read { db in
            try #require(try DBConversation.fetchOne(db, key: conversationId))
        }

        let messageWriter = IncomingMessageWriter(databaseWriter: dbManager.dbWriter)
        let messages = try await memberGroup.messages(direction: .ascending)
        var sawRemovedFromConversation = false
        for message in messages {
            guard let contentType = try? message.encodedContent.type,
                  contentType == ContentTypeGroupUpdated || contentType == ContentTypeLeaveRequest else {
                continue
            }
            let result = try await messageWriter.store(message: message, for: dbConversation)
            if result.wasRemovedFromConversation {
                sawRemovedFromConversation = true
            }
        }

        // No message the remaining member receives may mark THEM as removed.
        #expect(!sawRemovedFromConversation)

        let roster = try await memberGroup.members.map(\.inboxId)
        try await dbManager.dbWriter.write { db in
            _ = try ConversationWriter.reconcileMemberDepartures(
                conversationId: conversationId,
                mlsMemberInboxIds: Set(roster),
                in: db
            )
        }

        let creatorInboxId = creatorClient.inboxId
        let memberInboxId = memberClient.inboxId
        try await dbManager.dbReader.read { db in
            // The conversation row survives, unhidden.
            let conversation = try DBConversation.fetchOne(db, key: conversationId)
            #expect(conversation != nil)
            #expect(conversation?.consent == .allowed)
            let localState = try ConversationLocalState
                .filter(ConversationLocalState.Columns.conversationId == conversationId)
                .fetchOne(db)
            #expect(localState?.wasRemoved != true)

            // The regression the user hit: the conversations-list query joins
            // the creator's member row, and the departure ingest deletes that
            // row when the creator leaves. The conversation must still come
            // back from the detailed query and hydrate with a fallback
            // creator.
            let details = try DBConversation
                .filter(DBConversation.Columns.id == conversationId)
                .detailedConversationQuery()
                .fetchOne(db)
            let hydrated = try #require(details?.hydrateConversation(currentInboxId: memberInboxId))
            #expect(hydrated.creator.profile.inboxId == creatorInboxId)
            #expect(!hydrated.creator.isCurrentUser)
            #expect(hydrated.members.map(\.profile.inboxId) == [memberInboxId])

            // The leaver's member row is gone; the remaining member's stays.
            let creatorRow = try DBConversationMember
                .filter(DBConversationMember.Columns.conversationId == conversationId)
                .filter(DBConversationMember.Columns.inboxId == creatorClient.inboxId)
                .fetchOne(db)
            #expect(creatorRow == nil)
            let memberRow = try DBConversationMember
                .filter(DBConversationMember.Columns.conversationId == conversationId)
                .filter(DBConversationMember.Columns.inboxId == memberClient.inboxId)
                .fetchOne(db)
            #expect(memberRow != nil)

            // Exactly one visible "left" transcript row: the self-leave shape
            // (initiator == removed member == the creator).
            let updates = try DBMessage
                .filter(DBMessage.Columns.conversationId == conversationId)
                .filter(DBMessage.Columns.contentType == MessageContentType.update.rawValue)
                .fetchAll(db)
            let leaveUpdates = updates.filter { message in
                guard let update = message.update else { return false }
                return update.removedInboxIds == [creatorClient.inboxId]
                    && update.initiatedByInboxId == creatorClient.inboxId
            }
            #expect(leaveUpdates.count == 1)
        }
    }

    private static func seedConversation(
        db: Database,
        id: String,
        currentInboxId: String,
        otherInboxId: String
    ) throws {
        try DBMember(inboxId: currentInboxId).save(db, onConflict: .ignore)
        try DBInbox(
            inboxId: currentInboxId,
            clientId: "client-current",
            createdAt: Date()
        ).save(db, onConflict: .ignore)
        try DBMember(inboxId: otherInboxId).save(db, onConflict: .ignore)

        try DBConversation(
            id: id,
            clientConversationId: "client-\(id)",
            inviteTag: "tag-\(id)",
            creatorId: otherInboxId,
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

        try ConversationLocalState(
            conversationId: id,
            isPinned: false,
            isUnread: false,
            isUnreadUpdatedAt: Date(),
            isMuted: false,
            pinnedOrder: nil,
            hidesInviteCard: false,
            leftHostedInviteSession: false,
            wasRemoved: false,
            hasHadOtherMembers: false,
            hasSharedInvite: false
        ).insert(db)

        for inboxId in [currentInboxId, otherInboxId] {
            try DBConversationMember(
                conversationId: id,
                inboxId: inboxId,
                role: inboxId == otherInboxId ? .superAdmin : .member,
                consent: .allowed,
                createdAt: Date(),
                invitedByInboxId: nil
            ).insert(db)
            try DBMemberProfile(
                conversationId: id,
                inboxId: inboxId,
                name: nil,
                avatar: nil
            ).insert(db)
        }
    }
}
