#if canImport(UIKit)
import Combine
import Foundation
import GRDB
import UIKit
import XMTPiOS

public protocol OutgoingPhotoMessageWriterProtocol {
    var sentMessage: AnyPublisher<String, Never> { get }
    func send(image: UIImage) async throws
}

enum OutgoingPhotoMessageWriterError: Error {
    case missingClientProvider
}

class OutgoingPhotoMessageWriter: OutgoingPhotoMessageWriterProtocol {
    private let inboxStateManager: any InboxStateManagerProtocol
    private let databaseWriter: any DatabaseWriter
    private let conversationId: String
    private let photoService: any PhotoAttachmentServiceProtocol
    private let sentMessageSubject: PassthroughSubject<String, Never> = .init()

    var sentMessage: AnyPublisher<String, Never> {
        sentMessageSubject.eraseToAnyPublisher()
    }

    init(
        inboxStateManager: any InboxStateManagerProtocol,
        databaseWriter: any DatabaseWriter,
        conversationId: String,
        photoService: any PhotoAttachmentServiceProtocol = PhotoAttachmentService()
    ) {
        self.inboxStateManager = inboxStateManager
        self.databaseWriter = databaseWriter
        self.conversationId = conversationId
        self.photoService = photoService
    }

    func send(image: UIImage) async throws {
        let inboxReady = try await inboxStateManager.waitForInboxReadyResult()
        let client = inboxReady.client

        guard let sender = try await client.messageSender(for: conversationId) else {
            throw OutgoingPhotoMessageWriterError.missingClientProvider
        }

        let filename = photoService.generateFilename()
        let trackingKey = photoService.localCacheURL(for: filename).absoluteString
        let tracker = PhotoUploadProgressTracker.shared

        tracker.setStage(.preparing, for: trackingKey)

        let prepared: PreparedPhotoAttachment
        do {
            tracker.setStage(.uploading, for: trackingKey)
            prepared = try await photoService.prepareForSend(
                image: image,
                apiClient: inboxReady.apiClient,
                filename: filename
            )
        } catch {
            tracker.setStage(.failed, for: trackingKey)
            throw error
        }

        let clientMessageId = try await sender.prepare(remoteAttachment: prepared.remoteAttachment)

        let date = Date()
        try await databaseWriter.write { [weak self] db in
            guard let self else { return }

            let localMessage = DBMessage(
                id: clientMessageId,
                clientMessageId: clientMessageId,
                conversationId: conversationId,
                senderId: client.inboxId,
                dateNs: date.nanosecondsSince1970,
                date: date,
                status: .unpublished,
                messageType: .original,
                contentType: .attachments,
                text: nil,
                emoji: nil,
                invite: nil,
                sourceMessageId: nil,
                attachmentUrls: [prepared.localDisplayURL.absoluteString],
                update: nil
            )

            try localMessage.save(db)
            Log.info("Saved photo message with id: \(clientMessageId)")
        }

        do {
            tracker.setStage(.publishing, for: trackingKey)
            Log.info("Publishing photo message with id: \(clientMessageId)")
            try await sender.publish()

            // After publishing, update the message to use StoredRemoteAttachment JSON
            // This ensures the photo can be reloaded even if the local cache is cleared
            let storedAttachment = StoredRemoteAttachment(
                url: prepared.remoteAttachment.url,
                contentDigest: prepared.remoteAttachment.contentDigest,
                secret: prepared.remoteAttachment.secret,
                salt: prepared.remoteAttachment.salt,
                nonce: prepared.remoteAttachment.nonce,
                filename: prepared.remoteAttachment.filename
            )
            if let storedJSON = try? storedAttachment.toJSON() {
                // Pre-cache the image with the new JSON key before updating DB
                // This prevents a flash/reload when attachmentData changes from file:// to JSON
                if let imageData = try? Data(contentsOf: prepared.localDisplayURL),
                   let image = UIImage(data: imageData) {
                    ImageCacheContainer.shared.cacheImage(image, for: storedJSON)
                }

                try await databaseWriter.write { db in
                    guard let dbMessage = try DBMessage.fetchOne(db, key: clientMessageId) else {
                        return
                    }
                    try dbMessage
                        .with(attachmentUrls: [storedJSON])
                        .with(status: .published)
                        .save(db)
                }
            }

            tracker.setStage(.completed, for: trackingKey)
            sentMessageSubject.send(prepared.localDisplayURL.absoluteString)
            Log.info("Published photo message with id: \(clientMessageId)")
        } catch {
            tracker.setStage(.failed, for: trackingKey)
            Log.error("Failed publishing photo message: \(error)")
            do {
                try await databaseWriter.write { db in
                    guard let localMessage = try DBMessage.fetchOne(db, key: clientMessageId) else {
                        Log.warning("Local photo message not found after failing to send")
                        return
                    }
                    try localMessage.with(status: .failed).save(db)
                }
            } catch {
                Log.error("Failed updating failed photo message status: \(error.localizedDescription)")
            }
            throw error
        }
    }
}
#endif
