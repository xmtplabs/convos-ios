import Combine
import Foundation
import GRDB
import XMTPiOS

public protocol OutgoingMessageWriterProtocol {
    var sentMessage: AnyPublisher<String, Never> { get }
    func send(text: String) async throws
}

enum OutgoingMessageWriterError: Error {
    case missingClientProvider
}

class OutgoingMessageWriter: OutgoingMessageWriterProtocol {
    private let inboxStateManager: any InboxStateManagerProtocol
    private let databaseWriter: any DatabaseWriter
    private let conversationId: String
    private let isSendingValue: CurrentValueSubject<Bool, Never> = .init(false)
    private let sentMessageSubject: PassthroughSubject<String, Never> = .init()

    var sentMessage: AnyPublisher<String, Never> {
        sentMessageSubject.eraseToAnyPublisher()
    }

    init(inboxStateManager: any InboxStateManagerProtocol,
         databaseWriter: any DatabaseWriter,
         conversationId: String) {
        self.inboxStateManager = inboxStateManager
        self.databaseWriter = databaseWriter
        self.conversationId = conversationId
    }

    func send(text: String) async throws {
        let inboxReady = try await self.inboxStateManager.waitForInboxReadyResult()
        let client = inboxReady.client

        isSendingValue.send(true)

        defer {
            isSendingValue.send(false)
        }

        guard let sender = try await client.messageSender(
            for: conversationId
        ) else {
            throw OutgoingMessageWriterError.missingClientProvider
        }

        let clientMessageId: String = try await sender.prepare(text: text)

        let date = Date()
        try await databaseWriter.write { [weak self] db in
            guard let self else { return }

            let isContentEmoji = text.allCharactersEmoji
            let invite: MessageInvite?
            let trimmedText = text.trimmingCharacters(in: .whitespacesAndNewlines)
            if let url = URL(string: trimmedText),
               let inviteCode = url.convosInviteCode,
               let signedInvite = try? SignedInvite.fromInviteCode(inviteCode) {
                let imageURL: URL?
                if let image = signedInvite.imageURL {
                    imageURL = URL(string: image)
                } else {
                    imageURL = nil
                }
                invite = MessageInvite(
                    inviteSlug: inviteCode,
                    conversationName: signedInvite.name,
                    conversationDescription: signedInvite.description_p,
                    imageURL: imageURL,
                    expiresAt: signedInvite.expiresAt,
                    conversationExpiresAt: signedInvite.conversationExpiresAt
                )
            } else {
                invite = nil
            }

            let contentType: MessageContentType
            if isContentEmoji {
                contentType = .emoji
            } else if invite != nil {
                contentType = .invite
            } else {
                contentType = .text
            }

            let localMessage = DBMessage(
                id: clientMessageId,
                clientMessageId: clientMessageId,
                conversationId: conversationId,
                senderId: client.inboxId,
                dateNs: date.nanosecondsSince1970,
                date: date,
                status: .unpublished,
                messageType: .original,
                contentType: contentType,
                text: isContentEmoji ? nil : text,
                emoji: isContentEmoji ? text : nil,
                invite: invite,
                sourceMessageId: nil,
                attachmentUrls: [],
                update: nil
            )

            try localMessage.save(db)
            Log.info("Saved local message with local id: \(localMessage.clientMessageId)")
        }

        do {
            Log.info("Sending local message with local id: \(clientMessageId)")
            try await sender.publish()
            sentMessageSubject.send(text)
            Log.info("Sent local message with local id: \(clientMessageId)")
        } catch {
            Log.error("Failed sending message")
            do {
                try await databaseWriter.write { db in
                    guard let localMessage = try DBMessage.fetchOne(db, key: clientMessageId) else {
                        Log.warning("Local message not found after failing to send")
                        return
                    }

                    try localMessage.with(status: .failed).save(db)
                }
            } catch {
                Log.error("Failed updating failed message status: \(error.localizedDescription)")
            }

            throw error
        }
    }
}
