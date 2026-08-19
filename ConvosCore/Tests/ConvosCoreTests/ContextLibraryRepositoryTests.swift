@testable import ConvosCore
import Combine
import Foundation
import GRDB
import Testing

@Suite("ContextLibraryRepository Tests", .serialized)
@MainActor
struct ContextLibraryRepositoryTests {
    nonisolated private static let currentInboxId: String = "me"

    @Test("indexes supported context with scope, provenance, and newest-first order")
    func indexesSupportedContext() async throws {
        let dbManager = MockDatabaseManager.makeTestDatabase()
        try await dbManager.dbWriter.write { db in
            try Self.seedIdentityAndConversations(db)
            try Self.insertAttachment(
                db,
                id: "photo",
                conversationId: "included",
                senderId: Self.currentInboxId,
                date: Date(timeIntervalSince1970: 30),
                key: "file:///tmp/cache_Dinner.jpg"
            )
            try Self.insertLink(
                db,
                id: "link",
                conversationId: "included",
                senderId: "other",
                date: Date(timeIntervalSince1970: 20)
            )
            try Self.insertAttachment(
                db,
                id: "voice",
                conversationId: "included",
                senderId: "other",
                date: Date(timeIntervalSince1970: 10),
                key: "https://files.example.com/Thought.m4a"
            )
            try Self.insertAttachment(
                db,
                id: "excluded",
                conversationId: "excluded",
                senderId: "other",
                date: Date(timeIntervalSince1970: 40),
                key: "https://files.example.com/Secret.pdf"
            )
        }

        let repository = ContextLibraryRepository(dbReader: dbManager.dbReader)
        let items = await firstValue(from: repository.itemsPublisher(conversationIds: ["included"]))

        #expect(items.map(\.id) == ["attachment-photo-0", "link-link", "attachment-voice-0"])
        #expect(items.map(\.kind) == [.photo, .link, .voice])
        #expect(items[0].title == "Dinner.jpg")
        #expect(items[0].isMine)
        #expect(items[0].conversationId == "included")
        #expect(items[0].senderInboxId == Self.currentInboxId)
        #expect(items[1].destinationURLString == "https://example.com/launch")
        #expect(items[1].imageURLString == "https://cdn.example.com/launch.jpg")
        #expect(!items[1].isMine)
        #expect(items[2].title == "Thought.m4a")
        #expect(!items.contains { $0.id.contains("excluded") })
    }

    @Test("an empty conversation scope publishes an empty library")
    func emptyScope() async {
        let dbManager = MockDatabaseManager.makeTestDatabase()
        let repository = ContextLibraryRepository(dbReader: dbManager.dbReader)

        let items = await firstValue(from: repository.itemsPublisher(conversationIds: []))

        #expect(items.isEmpty)
    }

    private func firstValue(
        from publisher: AnyPublisher<[ContextLibraryItem], Never>
    ) async -> [ContextLibraryItem] {
        await withCheckedContinuation { continuation in
            var cancellable: AnyCancellable?
            cancellable = publisher.first().sink { items in
                continuation.resume(returning: items)
                cancellable?.cancel()
            }
        }
    }

    nonisolated private static func seedIdentityAndConversations(_ db: Database) throws {
        try DBMember(inboxId: currentInboxId).save(db, onConflict: .ignore)
        try DBMember(inboxId: "other").save(db, onConflict: .ignore)
        try DBInbox(inboxId: currentInboxId, clientId: "client-me").save(db, onConflict: .ignore)
        for id in ["included", "excluded"] {
            try DBConversation(
                id: id,
                clientConversationId: "client-\(id)",
                inviteTag: "tag-\(id)",
                creatorId: currentInboxId,
                kind: .group,
                consent: .allowed,
                createdAt: Date(timeIntervalSince1970: 0),
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
            ).save(db, onConflict: .ignore)
        }
    }

    nonisolated private static func insertAttachment(
        _ db: Database,
        id: String,
        conversationId: String,
        senderId: String,
        date: Date,
        key: String
    ) throws {
        try message(
            id: id,
            conversationId: conversationId,
            senderId: senderId,
            date: date,
            contentType: .attachments,
            linkPreview: nil,
            attachmentUrls: [key]
        ).insert(db)
    }

    nonisolated private static func insertLink(
        _ db: Database,
        id: String,
        conversationId: String,
        senderId: String,
        date: Date
    ) throws {
        try message(
            id: id,
            conversationId: conversationId,
            senderId: senderId,
            date: date,
            contentType: .linkPreview,
            linkPreview: LinkPreview(
                url: "https://example.com/launch",
                title: "Launch",
                imageURL: "https://cdn.example.com/launch.jpg"
            ),
            attachmentUrls: []
        ).insert(db)
    }

    nonisolated private static func message(
        id: String,
        conversationId: String,
        senderId: String,
        date: Date,
        contentType: MessageContentType,
        linkPreview: LinkPreview?,
        attachmentUrls: [String]
    ) -> DBMessage {
        DBMessage(
            id: id,
            clientMessageId: id,
            conversationId: conversationId,
            senderId: senderId,
            dateNs: Int64(date.timeIntervalSince1970 * 1_000_000_000),
            date: date,
            sortId: nil,
            status: .published,
            messageType: .original,
            contentType: contentType,
            text: nil,
            emoji: nil,
            invite: nil,
            linkPreview: linkPreview,
            sourceMessageId: nil,
            attachmentUrls: attachmentUrls,
            update: nil
        )
    }
}
