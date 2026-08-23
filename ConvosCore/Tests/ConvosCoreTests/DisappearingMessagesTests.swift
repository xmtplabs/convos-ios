@testable import ConvosCore
import Foundation
import GRDB
import Testing

@Suite("Disappearing messages", .serialized)
struct DisappearingMessagesTests {
    @Test("V1 timer choices match the product contract")
    func timerChoices() {
        #expect(DisappearingMessageDuration.allCases.map(\.title) == ["24 hours", "7 days", "90 days"])
        #expect(DisappearingMessageDuration.privacyDefault == .twentyFourHours)
    }

    @Test("Transcript notice communicates agent retention")
    func transcriptNotice() {
        let update = ConversationUpdate(
            creator: .mock(isCurrentUser: true),
            addedMembers: [],
            removedMembers: [],
            metadataChanges: [
                .init(
                    field: .disappearingMessages,
                    oldValue: nil,
                    newValue: String(DisappearingMessageDuration.sevenDays.rawValue)
                ),
            ]
        )

        #expect(update.summary.contains("turned on disappearing messages for 7 days"))
        #expect(update.summary.contains("agent"))
        #expect(update.summary.contains("outside Convos"))
    }

    @Test("Expired source messages and their replies leave the Convos database")
    func expiredMessagesArePruned() async throws {
        let databaseManager = MockDatabaseManager.makeTestDatabase()
        let now = Date()
        let conversationId = "disappearing-conversation"
        let senderId = "sender"

        try await databaseManager.dbWriter.write { db in
            try DBMember(inboxId: senderId).save(db, onConflict: .ignore)
            try DBConversation(
                id: conversationId,
                clientConversationId: "client-\(conversationId)",
                inviteTag: "tag-\(conversationId)",
                creatorId: senderId,
                kind: .group,
                consent: .allowed,
                createdAt: now,
                name: "Private conversation",
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
                hasHadVerifiedAgent: false,
                disappearingMessageRetentionDurationInNs: DisappearingMessageDuration.twentyFourHours.rawValue
            ).insert(db)

            try makeMessage(
                id: "expired",
                conversationId: conversationId,
                senderId: senderId,
                date: now.addingTimeInterval(-60),
                expiresAtNs: now.addingTimeInterval(-1).nanosecondsSince1970
            ).insert(db)
            try makeMessage(
                id: "reply-to-expired",
                conversationId: conversationId,
                senderId: senderId,
                date: now,
                sourceMessageId: "expired",
                expiresAtNs: now.addingTimeInterval(60).nanosecondsSince1970
            ).insert(db)
            try makeMessage(
                id: "still-present",
                conversationId: conversationId,
                senderId: senderId,
                date: now,
                expiresAtNs: now.addingTimeInterval(60).nanosecondsSince1970
            ).insert(db)
            try DBVoiceMemoTranscript(
                messageId: "expired",
                conversationId: conversationId,
                attachmentKey: "file:///already-removed.m4a",
                status: VoiceMemoTranscriptStatus.completed.rawValue,
                text: "private transcript",
                errorDescription: nil,
                createdAt: now,
                updatedAt: now
            ).insert(db)
            try DBPendingPhotoUpload(
                id: "stale-upload",
                clientMessageId: "expired",
                conversationId: conversationId,
                localCacheURL: "file:///already-removed.jpg",
                state: .completed,
                createdAt: now,
                updatedAt: now
            ).insert(db)
        }

        let writer = DisappearingMessageDeletionWriter(databaseWriter: databaseManager.dbWriter)
        try await writer.pruneExpiredMessages(now: now)

        let remaining = try await databaseManager.dbReader.read { db in
            let messages = try String.fetchAll(db, sql: "SELECT id FROM message ORDER BY id")
            let transcriptCount = try DBVoiceMemoTranscript.fetchCount(db)
            let pendingUploadCount = try DBPendingPhotoUpload.fetchCount(db)
            return (messages, transcriptCount, pendingUploadCount)
        }
        #expect(remaining.0 == ["still-present"])
        #expect(remaining.1 == 0)
        #expect(remaining.2 == 0)
    }

    private func makeMessage(
        id: String,
        conversationId: String,
        senderId: String,
        date: Date,
        sourceMessageId: String? = nil,
        expiresAtNs: Int64?
    ) -> DBMessage {
        DBMessage(
            id: id,
            clientMessageId: id,
            conversationId: conversationId,
            senderId: senderId,
            dateNs: date.nanosecondsSince1970,
            date: date,
            sortId: nil,
            status: .published,
            messageType: sourceMessageId == nil ? .original : .reply,
            contentType: .text,
            text: "private",
            emoji: nil,
            invite: nil,
            linkPreview: nil,
            sourceMessageId: sourceMessageId,
            attachmentUrls: [],
            update: nil,
            expiresAtNs: expiresAtNs
        )
    }
}
