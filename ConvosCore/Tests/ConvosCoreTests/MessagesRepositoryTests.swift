@testable import ConvosCore
import Foundation
import GRDB
import Testing

@Suite("MessagesRepository Tests", .serialized)
struct MessagesRepositoryTests {
    @Test("messages from removed members remain visible after member removal")
    func testMessagesFromRemovedMembersRemainVisible() throws {
        let dbManager = MockDatabaseManager.makeTestDatabase()
        let conversationId = "conversation-1"
        let currentInboxId = "current-user"
        let removedInboxId = "removed-user"
        let now = Date()

        try dbManager.dbWriter.write { db in
            try seedConversation(
                db: db,
                conversationId: conversationId,
                currentInboxId: currentInboxId,
                otherInboxIds: [removedInboxId],
                now: now
            )

            try DBMessage(
                id: "message-1",
                clientMessageId: "message-1",
                conversationId: conversationId,
                senderId: removedInboxId,
                dateNs: Int64(now.timeIntervalSince1970 * 1_000_000_000),
                date: now,
                sortId: 1,
                status: .published,
                messageType: .original,
                contentType: .text,
                text: "hello from removed member",
                emoji: nil,
                invite: nil,
                linkPreview: nil,
                sourceMessageId: nil,
                attachmentUrls: [],
                update: nil
            ).insert(db)

            try DBConversationMember
                .filter(DBConversationMember.Columns.conversationId == conversationId)
                .filter(DBConversationMember.Columns.inboxId == removedInboxId)
                .deleteAll(db)
        }

        let repository = MessagesRepository(dbReader: dbManager.dbReader, conversationId: conversationId, currentInboxId: "")
        let messages = try repository.fetchInitial()

        #expect(messages.count == 1)

        guard case .message(let message, _) = messages[0] else {
            Issue.record("Expected a standard message")
            return
        }

        #expect(message.sender.profile.inboxId == removedInboxId)
        #expect(message.sender.profile.displayName == "Removed")
    }

    @Test("messages from removed members still show with fallback profile when memberProfile is also deleted")
    func testMessagesFromRemovedMembersAfterProfileDeletion() throws {
        let dbManager = MockDatabaseManager.makeTestDatabase()
        let conversationId = "conversation-1"
        let currentInboxId = "current-user"
        let removedInboxId = "removed-user"
        let now = Date()

        try dbManager.dbWriter.write { db in
            try seedConversation(
                db: db,
                conversationId: conversationId,
                currentInboxId: currentInboxId,
                otherInboxIds: [removedInboxId],
                now: now
            )

            try DBMessage(
                id: "message-1",
                clientMessageId: "message-1",
                conversationId: conversationId,
                senderId: removedInboxId,
                dateNs: Int64(now.timeIntervalSince1970 * 1_000_000_000),
                date: now,
                sortId: 1,
                status: .published,
                messageType: .original,
                contentType: .text,
                text: "hello from removed member",
                emoji: nil,
                invite: nil,
                linkPreview: nil,
                sourceMessageId: nil,
                attachmentUrls: [],
                update: nil
            ).insert(db)

            try DBConversationMember
                .filter(DBConversationMember.Columns.conversationId == conversationId)
                .filter(DBConversationMember.Columns.inboxId == removedInboxId)
                .deleteAll(db)

            try DBMemberProfile
                .filter(DBMemberProfile.Columns.conversationId == conversationId)
                .filter(DBMemberProfile.Columns.inboxId == removedInboxId)
                .deleteAll(db)
        }

        let repository = MessagesRepository(dbReader: dbManager.dbReader, conversationId: conversationId, currentInboxId: "")
        let messages = try repository.fetchInitial()

        #expect(messages.count == 1)
        guard case .message(let message, _) = messages[0] else {
            Issue.record("Expected a standard message")
            return
        }
        #expect(message.sender.profile.inboxId == removedInboxId)
        #expect(message.sender.profile.displayName == "Somebody")
    }

    @Test("reactions from removed members remain visible")
    func testReactionsFromRemovedMembersRemainVisible() throws {
        let dbManager = MockDatabaseManager.makeTestDatabase()
        let conversationId = "conversation-1"
        let currentInboxId = "current-user"
        let removedInboxId = "removed-user"
        let now = Date()

        try dbManager.dbWriter.write { db in
            try seedConversation(
                db: db,
                conversationId: conversationId,
                currentInboxId: currentInboxId,
                otherInboxIds: [removedInboxId],
                now: now
            )

            try DBMessage(
                id: "message-1",
                clientMessageId: "message-1",
                conversationId: conversationId,
                senderId: currentInboxId,
                dateNs: Int64(now.timeIntervalSince1970 * 1_000_000_000),
                date: now,
                sortId: 1,
                status: .published,
                messageType: .original,
                contentType: .text,
                text: "hello",
                emoji: nil,
                invite: nil,
                linkPreview: nil,
                sourceMessageId: nil,
                attachmentUrls: [],
                update: nil
            ).insert(db)

            try DBMessage(
                id: "reaction-1",
                clientMessageId: "reaction-1",
                conversationId: conversationId,
                senderId: removedInboxId,
                dateNs: Int64(now.timeIntervalSince1970 * 1_000_000_000) + 1_000_000_000,
                date: now.addingTimeInterval(1),
                sortId: 2,
                status: .published,
                messageType: .reaction,
                contentType: .emoji,
                text: nil,
                emoji: "👍",
                invite: nil,
                linkPreview: nil,
                sourceMessageId: "message-1",
                attachmentUrls: [],
                update: nil
            ).insert(db)

            try DBConversationMember
                .filter(DBConversationMember.Columns.conversationId == conversationId)
                .filter(DBConversationMember.Columns.inboxId == removedInboxId)
                .deleteAll(db)
        }

        let repository = MessagesRepository(dbReader: dbManager.dbReader, conversationId: conversationId, currentInboxId: "")
        let messages = try repository.fetchInitial()

        #expect(messages.count == 1)
        guard case .message(let message, _) = messages[0] else {
            Issue.record("Expected a standard message")
            return
        }
        #expect(message.reactions.count == 1)
        #expect(message.reactions[0].sender.profile.inboxId == removedInboxId)
    }

    @Test("replies from removed members remain visible")
    func testRepliesFromRemovedMembersRemainVisible() throws {
        let dbManager = MockDatabaseManager.makeTestDatabase()
        let conversationId = "conversation-1"
        let currentInboxId = "current-user"
        let removedInboxId = "removed-user"
        let now = Date()

        try dbManager.dbWriter.write { db in
            try seedConversation(
                db: db,
                conversationId: conversationId,
                currentInboxId: currentInboxId,
                otherInboxIds: [removedInboxId],
                now: now
            )

            try DBMessage(
                id: "message-1",
                clientMessageId: "message-1",
                conversationId: conversationId,
                senderId: currentInboxId,
                dateNs: Int64(now.timeIntervalSince1970 * 1_000_000_000),
                date: now,
                sortId: 1,
                status: .published,
                messageType: .original,
                contentType: .text,
                text: "hello",
                emoji: nil,
                invite: nil,
                linkPreview: nil,
                sourceMessageId: nil,
                attachmentUrls: [],
                update: nil
            ).insert(db)

            try DBMessage(
                id: "reply-1",
                clientMessageId: "reply-1",
                conversationId: conversationId,
                senderId: removedInboxId,
                dateNs: Int64(now.timeIntervalSince1970 * 1_000_000_000) + 1_000_000_000,
                date: now.addingTimeInterval(1),
                sortId: 2,
                status: .published,
                messageType: .reply,
                contentType: .text,
                text: "replying!",
                emoji: nil,
                invite: nil,
                linkPreview: nil,
                sourceMessageId: "message-1",
                attachmentUrls: [],
                update: nil
            ).insert(db)

            try DBConversationMember
                .filter(DBConversationMember.Columns.conversationId == conversationId)
                .filter(DBConversationMember.Columns.inboxId == removedInboxId)
                .deleteAll(db)
        }

        let repository = MessagesRepository(dbReader: dbManager.dbReader, conversationId: conversationId, currentInboxId: "")
        let messages = try repository.fetchInitial()

        #expect(messages.count == 2)

        let reply = messages.first(where: {
            if case .reply = $0 { return true }
            return false
        })
        #expect(reply != nil)

        if case .reply(let replyMessage, _) = reply {
            #expect(replyMessage.sender.profile.inboxId == removedInboxId)
            #expect(replyMessage.sender.profile.displayName == "Removed")
        }
    }

    @Test("saveConversationToDatabase preserves memberProfile rows for removed members")
    func testSaveConversationPreservesHistoricalProfiles() throws {
        let dbManager = MockDatabaseManager.makeTestDatabase()
        let conversationId = "conversation-1"
        let currentInboxId = "current-user"
        let removedInboxId = "removed-user"
        let now = Date()

        try dbManager.dbWriter.write { db in
            try seedConversation(
                db: db,
                conversationId: conversationId,
                currentInboxId: currentInboxId,
                otherInboxIds: [removedInboxId],
                now: now
            )

            try DBMessage(
                id: "message-1",
                clientMessageId: "message-1",
                conversationId: conversationId,
                senderId: removedInboxId,
                dateNs: Int64(now.timeIntervalSince1970 * 1_000_000_000),
                date: now,
                sortId: 1,
                status: .published,
                messageType: .original,
                contentType: .text,
                text: "hello",
                emoji: nil,
                invite: nil,
                linkPreview: nil,
                sourceMessageId: nil,
                attachmentUrls: [],
                update: nil
            ).insert(db)

            try DBConversationMember
                .filter(DBConversationMember.Columns.conversationId == conversationId)
                .filter(DBConversationMember.Columns.inboxId == removedInboxId)
                .deleteAll(db)
        }

        let removedProfileExists = try dbManager.dbReader.read { db in
            try DBMemberProfile.fetchOne(db, conversationId: conversationId, inboxId: removedInboxId)
        }
        #expect(removedProfileExists != nil, "memberProfile for removed member should still exist")
        #expect(removedProfileExists?.name == "Removed")
    }

    @Test("conversation sync upserts current member profiles without deleting historical ones")
    func testConversationSyncPreservesHistoricalProfiles() throws {
        let dbManager = MockDatabaseManager.makeTestDatabase()
        let conversationId = "conversation-1"
        let currentInboxId = "current-user"
        let removedInboxId = "removed-user"
        let now = Date()

        try dbManager.dbWriter.write { db in
            try seedConversation(
                db: db,
                conversationId: conversationId,
                currentInboxId: currentInboxId,
                otherInboxIds: [removedInboxId],
                now: now
            )
        }

        let currentMemberProfile = DBMemberProfile(
            conversationId: conversationId,
            inboxId: currentInboxId,
            name: "Updated Current",
            avatar: "new-avatar-url"
        )

        try dbManager.dbWriter.write { db in
            try DBConversationMember
                .filter(DBConversationMember.Columns.conversationId == conversationId)
                .filter(DBConversationMember.Columns.inboxId == removedInboxId)
                .deleteAll(db)

            let currentInboxIds = [currentInboxId]
            try DBConversationMember
                .filter(DBConversationMember.Columns.conversationId == conversationId)
                .filter(!currentInboxIds.contains(DBConversationMember.Columns.inboxId))
                .deleteAll(db)

            let member = DBMember(inboxId: currentInboxId)
            try member.save(db)
            try currentMemberProfile.save(db)
        }

        let profiles = try dbManager.dbReader.read { db in
            try DBMemberProfile
                .filter(DBMemberProfile.Columns.conversationId == conversationId)
                .fetchAll(db)
        }

        let removedProfile = profiles.first(where: { $0.inboxId == removedInboxId })
        let updatedProfile = profiles.first(where: { $0.inboxId == currentInboxId })

        #expect(profiles.count == 2)
        #expect(removedProfile != nil, "historical profile for removed member should be preserved")
        #expect(removedProfile?.name == "Removed")
        #expect(updatedProfile?.name == "Updated Current")
        #expect(updatedProfile?.avatar == "new-avatar-url")
    }

    @Test("MessageInvite exposes isConversationExpired from conversationExpiresAt")
    func testMessageInviteIsConversationExpired() {
        let expired = MessageInvite(
            inviteSlug: "s",
            conversationName: nil,
            conversationDescription: nil,
            imageURL: nil,
            emoji: nil,
            expiresAt: nil,
            conversationExpiresAt: Date().addingTimeInterval(-60)
        )
        #expect(expired.isConversationExpired)
        #expect(!expired.isInviteExpired)

        let live = MessageInvite(
            inviteSlug: "s",
            conversationName: nil,
            conversationDescription: nil,
            imageURL: nil,
            emoji: nil,
            expiresAt: nil,
            conversationExpiresAt: Date().addingTimeInterval(3_600)
        )
        #expect(!live.isConversationExpired)

        let noExpiry = MessageInvite(
            inviteSlug: "s",
            conversationName: nil,
            conversationDescription: nil,
            imageURL: nil,
            emoji: nil,
            expiresAt: nil,
            conversationExpiresAt: nil
        )
        #expect(!noExpiry.isConversationExpired)
    }

    @Test("MessageInvite exposes isInviteExpired independently of conversationExpiresAt")
    func testMessageInviteIsInviteExpired() {
        let inviteExpired = MessageInvite(
            inviteSlug: "s",
            conversationName: nil,
            conversationDescription: nil,
            imageURL: nil,
            emoji: nil,
            expiresAt: Date().addingTimeInterval(-60),
            conversationExpiresAt: Date().addingTimeInterval(3_600)
        )
        #expect(inviteExpired.isInviteExpired)
        #expect(!inviteExpired.isConversationExpired)

        let live = MessageInvite(
            inviteSlug: "s",
            conversationName: nil,
            conversationDescription: nil,
            imageURL: nil,
            emoji: nil,
            expiresAt: Date().addingTimeInterval(3_600),
            conversationExpiresAt: nil
        )
        #expect(!live.isInviteExpired)
    }

    // MARK: - Helpers

    private func seedConversation(
        db: Database,
        conversationId: String,
        currentInboxId: String,
        otherInboxIds: [String],
        now: Date
    ) throws {
        try DBMember(inboxId: currentInboxId).save(db, onConflict: .ignore)
        for inboxId in otherInboxIds {
            try DBMember(inboxId: inboxId).save(db, onConflict: .ignore)
        }

        try DBConversation(
            id: conversationId,
                        clientConversationId: "client-\(conversationId)",
            inviteTag: "invite-tag-\(conversationId)",
            creatorId: currentInboxId,
            kind: .group,
            consent: .allowed,
            createdAt: now,
            name: "Test",
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
            hasHadVerifiedAssistant: false,
        ).insert(db)

        try ConversationLocalState(
            conversationId: conversationId,
            isPinned: false,
            isUnread: false,
            isUnreadUpdatedAt: now,
            isMuted: false,
            pinnedOrder: nil
        ).insert(db)

        try DBConversationMember(
            conversationId: conversationId,
            inboxId: currentInboxId,
            role: .superAdmin,
            consent: .allowed,
            createdAt: now,
            invitedByInboxId: nil
        ).insert(db)

        try DBMemberProfile(
            conversationId: conversationId,
            inboxId: currentInboxId,
            name: "Current",
            avatar: nil
        ).insert(db)

        for inboxId in otherInboxIds {
            try DBConversationMember(
                conversationId: conversationId,
                inboxId: inboxId,
                role: .member,
                consent: .allowed,
                createdAt: now,
                invitedByInboxId: nil
            ).insert(db)

            try DBMemberProfile(
                conversationId: conversationId,
                inboxId: inboxId,
                name: "Removed",
                avatar: nil
            ).insert(db)
        }
    }
}
