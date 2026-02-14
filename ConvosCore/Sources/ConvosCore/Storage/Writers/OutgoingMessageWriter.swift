import Combine
import Foundation
import GRDB
@preconcurrency import XMTPiOS

public protocol OutgoingMessageWriterProtocol: Sendable {
    var sentMessage: AnyPublisher<String, Never> { get }
    func send(text: String) async throws
    func send(text: String, afterPhoto trackingKey: String?) async throws
    func send(image: ImageType) async throws

    /// Start uploading a photo eagerly (before user taps Send).
    /// Returns a tracking key that can be used with `sendEagerPhoto` or `cancelEagerUpload`.
    func startEagerUpload(image: ImageType) async throws -> String

    /// Send a photo that was already started with `startEagerUpload`.
    /// Waits for upload to complete if still in progress, then sends via XMTP.
    func sendEagerPhoto(trackingKey: String) async throws

    /// Cancel an eager upload that was started but not sent.
    func cancelEagerUpload(trackingKey: String) async

    // MARK: - Replies

    /// Send a text reply to an existing message.
    func sendReply(text: String, toMessageWithClientId parentClientMessageId: String) async throws

    /// Send a photo reply that was already started with `startEagerUpload`.
    func sendEagerPhotoReply(trackingKey: String, toMessageWithClientId parentClientMessageId: String) async throws

    /// Send text after a photo reply (both replying to the same parent).
    func sendReply(text: String, afterPhoto trackingKey: String?, toMessageWithClientId parentClientMessageId: String) async throws
}

enum OutgoingMessageWriterError: Error {
    case missingClientProvider
    case eagerUploadNotFound
    case parentMessageNotFound
}

// swiftlint:disable:next type_body_length
actor OutgoingMessageWriter: OutgoingMessageWriterProtocol {
    private struct ReplyContext {
        let parentDbId: String
    }

    private struct QueuedTextMessage {
        let clientMessageId: String
        let text: String
        let dependsOnPhotoKey: String?
        let replyContext: ReplyContext?
    }

    private struct QueuedPhotoMessage {
        let clientMessageId: String
        let image: ImageType
        let localCacheURL: URL
        let filename: String
    }

    private struct EagerUploadState {
        let clientMessageId: String
        let image: ImageType
        let localCacheURL: URL
        let filename: String
        let prepared: PreparedBackgroundUpload
        var uploadCompleted: Bool = false
        var uploadError: Error?
        var waitingContinuation: CheckedContinuation<Void, Error>?
        var replyContext: ReplyContext?
    }

    private struct QueuedEagerPhoto {
        let trackingKey: String
    }

    private enum QueuedMessage {
        case text(QueuedTextMessage)
        case photo(QueuedPhotoMessage)
        case eagerPhoto(QueuedEagerPhoto)
    }

    private let inboxStateManager: any InboxStateManagerProtocol
    private let databaseWriter: any DatabaseWriter
    private let conversationId: String
    private let photoService: any PhotoAttachmentServiceProtocol
    private let pendingUploadWriter: any PendingPhotoUploadWriterProtocol
    private let backgroundUploadManager: any BackgroundUploadManagerProtocol
    private let attachmentLocalStateWriter: any AttachmentLocalStateWriterProtocol

    private var messageQueue: [QueuedMessage] = []
    private var isProcessingQueue: Bool = false
    private var eagerUploads: [String: EagerUploadState] = [:]
    private var publishedPhotoKeys: Set<String> = []
    private var pendingTexts: [QueuedTextMessage] = []

    nonisolated(unsafe) private let sentMessageSubject: PassthroughSubject<String, Never> = .init()

    nonisolated var sentMessage: AnyPublisher<String, Never> {
        sentMessageSubject.eraseToAnyPublisher()
    }

    init(
        inboxStateManager: any InboxStateManagerProtocol,
        databaseWriter: any DatabaseWriter,
        conversationId: String,
        photoService: any PhotoAttachmentServiceProtocol,
        pendingUploadWriter: any PendingPhotoUploadWriterProtocol,
        backgroundUploadManager: any BackgroundUploadManagerProtocol,
        attachmentLocalStateWriter: any AttachmentLocalStateWriterProtocol
    ) {
        self.inboxStateManager = inboxStateManager
        self.databaseWriter = databaseWriter
        self.conversationId = conversationId
        self.photoService = photoService
        self.pendingUploadWriter = pendingUploadWriter
        self.backgroundUploadManager = backgroundUploadManager
        self.attachmentLocalStateWriter = attachmentLocalStateWriter
    }

    func send(text: String) async throws {
        try await send(text: text, afterPhoto: nil)
    }

    func send(text: String, afterPhoto trackingKey: String?) async throws {
        try await sendText(text, afterPhoto: trackingKey, replyContext: nil)
    }

    private func sendText(_ text: String, afterPhoto trackingKey: String?, replyContext: ReplyContext?) async throws {
        let clientMessageId = UUID().uuidString
        try await saveTextToDatabase(clientMessageId: clientMessageId, text: text, replyContext: replyContext)

        let queued = QueuedTextMessage(
            clientMessageId: clientMessageId,
            text: text,
            dependsOnPhotoKey: trackingKey,
            replyContext: replyContext
        )

        // If this text depends on a photo that hasn't been published yet, defer it
        if let photoKey = trackingKey, !publishedPhotoKeys.contains(photoKey) {
            pendingTexts.append(queued)
            Log.info("Text message \(clientMessageId) deferred, waiting for photo \(photoKey)")
        } else {
            messageQueue.append(.text(queued))
            startProcessingIfNeeded()
        }
    }

    func send(image: ImageType) async throws {
        let clientMessageId = UUID().uuidString
        let filename = photoService.generateFilename()
        let localCacheURL = photoService.localCacheURL(for: filename)

        ImageCacheContainer.shared.cacheImage(image, for: localCacheURL.absoluteString)

        // Save dimensions FIRST so they're available when the UI observes the message
        try await attachmentLocalStateWriter.saveWithDimensions(
            attachmentKey: localCacheURL.absoluteString,
            conversationId: conversationId,
            width: Int(image.size.width),
            height: Int(image.size.height)
        )

        // Now save to database - dimensions will already be available for initial render
        try await savePhotoToDatabase(clientMessageId: clientMessageId, localCacheURL: localCacheURL)

        let queued = QueuedPhotoMessage(
            clientMessageId: clientMessageId,
            image: image,
            localCacheURL: localCacheURL,
            filename: filename
        )
        messageQueue.append(.photo(queued))
        startProcessingIfNeeded()
    }

    // MARK: - Eager Upload

    func startEagerUpload(image: ImageType) async throws -> String {
        let clientMessageId = UUID().uuidString
        let filename = photoService.generateFilename()
        let localCacheURL = photoService.localCacheURL(for: filename)
        let trackingKey = localCacheURL.absoluteString

        Log.info("Starting eager upload for trackingKey: \(trackingKey)")

        // Cache the image but do NOT save to database yet - that happens when user taps Send
        ImageCacheContainer.shared.cacheImage(image, for: trackingKey)

        let tracker = PhotoUploadProgressTracker.shared
        tracker.setStage(.preparing, for: trackingKey)

        let inboxReady = try await inboxStateManager.waitForInboxReadyResult()

        let prepared: PreparedBackgroundUpload
        do {
            prepared = try await photoService.prepareForBackgroundUpload(
                image: image,
                apiClient: inboxReady.apiClient,
                filename: filename
            )
        } catch {
            tracker.setStage(.failed, for: trackingKey)
            try? await markMessageFailed(clientMessageId: clientMessageId)
            throw error
        }

        let pendingUpload = DBPendingPhotoUpload(
            id: prepared.taskId,
            clientMessageId: clientMessageId,
            conversationId: conversationId,
            localCacheURL: trackingKey,
            state: .uploading
        )
        try await pendingUploadWriter.create(pendingUpload)

        var state = EagerUploadState(
            clientMessageId: clientMessageId,
            image: image,
            localCacheURL: localCacheURL,
            filename: filename,
            prepared: prepared
        )

        tracker.setProgress(stage: .uploading, percentage: 0, for: trackingKey)

        // Store state before starting upload
        eagerUploads[trackingKey] = state

        do {
            try await backgroundUploadManager.startUpload(
                fileURL: prepared.encryptedFileURL,
                uploadURL: prepared.presignedUploadURL,
                contentType: "application/octet-stream",
                taskId: prepared.taskId
            )
        } catch {
            // Clean up state on failure
            eagerUploads.removeValue(forKey: trackingKey)

            tracker.setStage(.failed, for: trackingKey)
            try await pendingUploadWriter.updateState(
                taskId: prepared.taskId,
                state: .failed,
                errorMessage: error.localizedDescription
            )
            try? await markMessageFailed(clientMessageId: clientMessageId)
            throw error
        }

        // Spawn a dedicated task to wait for this specific upload's completion
        // This avoids the race condition where multiple writers compete for a shared stream
        let taskId = prepared.taskId
        Task { [weak self] in
            guard let self else { return }
            await self.handleUploadCompletion(taskId: taskId, trackingKey: trackingKey)
        }

        return trackingKey
    }

    /// Waits for a specific upload to complete and updates the eager upload state.
    /// Each eager upload gets its own dedicated waiter to avoid race conditions.
    private func handleUploadCompletion(taskId: String, trackingKey: String) async {
        let tracker = PhotoUploadProgressTracker.shared
        let result = await backgroundUploadManager.waitForCompletion(taskId: taskId)

        Log.info("handleUploadCompletion: Received result for taskId: \(taskId), success: \(result.success)")

        if result.success {
            try? await pendingUploadWriter.updateState(taskId: taskId, state: .sending, errorMessage: nil)
            if var state = eagerUploads[trackingKey] {
                state.uploadCompleted = true
                let continuation = state.waitingContinuation
                state.waitingContinuation = nil
                eagerUploads[trackingKey] = state
                Log.info("handleUploadCompletion: Upload succeeded, has continuation: \(continuation != nil)")
                continuation?.resume()
            } else {
                Log.warning("handleUploadCompletion: No state found for trackingKey: \(trackingKey)")
            }
            Log.info("Eager upload completed successfully for: \(trackingKey)")
        } else {
            tracker.setStage(.failed, for: trackingKey)
            try? await pendingUploadWriter.updateState(
                taskId: taskId,
                state: .failed,
                errorMessage: result.error?.localizedDescription
            )
            if var state = eagerUploads[trackingKey] {
                state.uploadError = result.error
                let continuation = state.waitingContinuation
                state.waitingContinuation = nil
                eagerUploads[trackingKey] = state
                let error: Error = result.error ?? PhotoAttachmentError.uploadFailed("Eager upload failed")
                continuation?.resume(throwing: error)
            }
            if let state = eagerUploads[trackingKey] {
                try? await markMessageFailed(clientMessageId: state.clientMessageId)
            }
            Log.error("Eager upload failed for: \(trackingKey)")
        }
    }

    func sendEagerPhoto(trackingKey: String) async throws {
        guard let state = eagerUploads[trackingKey] else {
            throw OutgoingMessageWriterError.eagerUploadNotFound
        }

        // Save dimensions FIRST so they're available when the UI observes the message
        try await attachmentLocalStateWriter.saveWithDimensions(
            attachmentKey: trackingKey,
            conversationId: conversationId,
            width: Int(state.image.size.width),
            height: Int(state.image.size.height)
        )

        // Now save to database - this makes the message appear in the UI
        // Dimensions will already be available for the initial render
        try await savePhotoToDatabase(clientMessageId: state.clientMessageId, localCacheURL: state.localCacheURL, replyContext: state.replyContext)

        // Queue for background processing (upload completion + XMTP send)
        // This returns immediately so text messages can also save to DB right away
        messageQueue.append(.eagerPhoto(QueuedEagerPhoto(trackingKey: trackingKey)))
        startProcessingIfNeeded()
    }

    private func processEagerPhoto(trackingKey: String) async throws {
        guard var state = eagerUploads[trackingKey] else {
            throw OutgoingMessageWriterError.eagerUploadNotFound
        }

        // If upload is still in progress, wait for it using continuation
        if !state.uploadCompleted && state.uploadError == nil {
            Log.info("processEagerPhoto: Upload not complete, waiting for continuation...")
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                state.waitingContinuation = continuation
                eagerUploads[trackingKey] = state
                Log.info("processEagerPhoto: Continuation stored, suspending...")
            }
            Log.info("processEagerPhoto: Continuation resumed!")
            guard let updatedState = eagerUploads[trackingKey] else {
                throw OutgoingMessageWriterError.eagerUploadNotFound
            }
            state = updatedState
        } else {
            Log.info("processEagerPhoto: Upload already complete, proceeding immediately")
        }

        if let error = state.uploadError {
            throw error
        }

        let tracker = PhotoUploadProgressTracker.shared
        tracker.setStage(.publishing, for: trackingKey)

        let inboxReady = try await inboxStateManager.waitForInboxReadyResult()
        let queued = QueuedPhotoMessage(
            clientMessageId: state.clientMessageId,
            image: state.image,
            localCacheURL: state.localCacheURL,
            filename: state.filename
        )

        try await completeXMTPSend(
            queued: queued,
            prepared: state.prepared,
            trackingKey: trackingKey,
            inboxReady: inboxReady,
            replyContext: state.replyContext
        )

        eagerUploads.removeValue(forKey: trackingKey)
    }

    func cancelEagerUpload(trackingKey: String) async {
        guard let state = eagerUploads[trackingKey] else { return }

        Log.info("Cancelling eager upload for: \(trackingKey)")

        await backgroundUploadManager.cancelUpload(taskId: state.prepared.taskId)

        try? await pendingUploadWriter.delete(taskId: state.prepared.taskId)
        try? FileManager.default.removeItem(at: state.prepared.encryptedFileURL)

        // Note: No need to delete from DBMessage - the message was never saved to the database
        // (that only happens in sendEagerPhoto when user taps Send)

        PhotoUploadProgressTracker.shared.clear(key: trackingKey)

        eagerUploads.removeValue(forKey: trackingKey)
    }

    // MARK: - Replies

    func sendReply(text: String, toMessageWithClientId parentClientMessageId: String) async throws {
        let replyContext = try await resolveReplyContext(parentClientMessageId: parentClientMessageId)
        try await sendText(text, afterPhoto: nil, replyContext: replyContext)
    }

    func sendReply(text: String, afterPhoto trackingKey: String?, toMessageWithClientId parentClientMessageId: String) async throws {
        let replyContext = try await resolveReplyContext(parentClientMessageId: parentClientMessageId)
        try await sendText(text, afterPhoto: trackingKey, replyContext: replyContext)
    }

    func sendEagerPhotoReply(trackingKey: String, toMessageWithClientId parentClientMessageId: String) async throws {
        let replyContext = try await resolveReplyContext(parentClientMessageId: parentClientMessageId)

        guard var state = eagerUploads[trackingKey] else {
            throw OutgoingMessageWriterError.eagerUploadNotFound
        }
        state.replyContext = replyContext
        eagerUploads[trackingKey] = state

        try await sendEagerPhoto(trackingKey: trackingKey)
    }

    private func resolveReplyContext(parentClientMessageId: String) async throws -> ReplyContext {
        let parentDbId = try await databaseWriter.read { db -> String in
            guard let parent = try DBMessage
                .filter(DBMessage.Columns.clientMessageId == parentClientMessageId)
                .fetchOne(db),
                  parent.status == .published else {
                throw OutgoingMessageWriterError.parentMessageNotFound
            }
            return parent.id
        }
        return ReplyContext(parentDbId: parentDbId)
    }

    private func startProcessingIfNeeded() {
        guard !isProcessingQueue else { return }
        Task { await processQueue() }
    }

    private func processQueue() async {
        guard !isProcessingQueue else { return }
        isProcessingQueue = true

        defer { isProcessingQueue = false }

        while !messageQueue.isEmpty {
            let message = messageQueue.removeFirst()
            do {
                switch message {
                case .text(let queued):
                    try await publishText(queued)
                case .photo(let queued):
                    try await publishPhoto(queued)
                case .eagerPhoto(let queued):
                    try await processEagerPhoto(trackingKey: queued.trackingKey)
                }
            } catch {
                Log.error("Failed to publish message: \(error)")
            }
        }
    }

    // MARK: - Database Save (Optimistic)

    private func saveTextToDatabase(clientMessageId: String, text: String, replyContext: ReplyContext? = nil) async throws {
        let senderId: String
        if case .ready(_, let result) = inboxStateManager.currentState {
            senderId = result.client.inboxId
        } else if case .backgrounded(_, let result) = inboxStateManager.currentState {
            senderId = result.client.inboxId
        } else {
            let inboxReady = try await inboxStateManager.waitForInboxReadyResult()
            senderId = inboxReady.client.inboxId
        }

        let date = Date()
        let conversationId = self.conversationId
        let isContentEmoji = text.allCharactersEmoji
        let trimmedText = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let invite = MessageInvite.from(text: text)

        let contentType: MessageContentType
        if isContentEmoji {
            contentType = .emoji
        } else if invite != nil {
            contentType = .invite
        } else {
            contentType = .text
        }

        try await databaseWriter.write { db in
            // Compute sortId as max + 1 for this conversation to maintain insertion order
            let maxSortId = try Int64.fetchOne(db, sql: """
                SELECT COALESCE(MAX(sortId), 0) FROM message WHERE conversationId = ?
            """, arguments: [conversationId]) ?? 0
            let sortId = maxSortId + 1

            let localMessage = DBMessage(
                id: clientMessageId,
                clientMessageId: clientMessageId,
                conversationId: conversationId,
                senderId: senderId,
                dateNs: date.nanosecondsSince1970,
                date: date,
                sortId: sortId,
                status: .unpublished,
                messageType: replyContext != nil ? .reply : .original,
                contentType: contentType,
                text: isContentEmoji ? nil : text,
                emoji: isContentEmoji ? trimmedText : nil,
                invite: invite,
                sourceMessageId: replyContext?.parentDbId,
                attachmentUrls: [],
                update: nil
            )
            try localMessage.save(db)
            Log.info("Saved text message optimistically with id: \(clientMessageId) sortId=\(sortId)")
        }
    }

    private func savePhotoToDatabase(clientMessageId: String, localCacheURL: URL, replyContext: ReplyContext? = nil) async throws {
        let senderId: String
        if case .ready(_, let result) = inboxStateManager.currentState {
            senderId = result.client.inboxId
        } else if case .backgrounded(_, let result) = inboxStateManager.currentState {
            senderId = result.client.inboxId
        } else {
            let inboxReady = try await inboxStateManager.waitForInboxReadyResult()
            senderId = inboxReady.client.inboxId
        }

        let date = Date()
        let conversationId = self.conversationId

        try await databaseWriter.write { db in
            // Compute sortId as max + 1 for this conversation to maintain insertion order
            let maxSortId = try Int64.fetchOne(db, sql: """
                SELECT COALESCE(MAX(sortId), 0) FROM message WHERE conversationId = ?
            """, arguments: [conversationId]) ?? 0
            let sortId = maxSortId + 1

            let localMessage = DBMessage(
                id: clientMessageId,
                clientMessageId: clientMessageId,
                conversationId: conversationId,
                senderId: senderId,
                dateNs: date.nanosecondsSince1970,
                date: date,
                sortId: sortId,
                status: .unpublished,
                messageType: replyContext != nil ? .reply : .original,
                contentType: .attachments,
                text: nil,
                emoji: nil,
                invite: nil,
                sourceMessageId: replyContext?.parentDbId,
                attachmentUrls: [localCacheURL.absoluteString],
                update: nil
            )
            try localMessage.save(db)
            Log.info("Saved photo message optimistically with clientMessageId: \(clientMessageId) sortId=\(sortId)")
        }
    }

    // MARK: - Network Publishing (Sequential)

    private func publishText(_ queued: QueuedTextMessage) async throws {
        let inboxReady = try await inboxStateManager.waitForInboxReadyResult()
        let client = inboxReady.client

        guard let sender = try await client.messageSender(for: conversationId) else {
            try? await markMessageFailed(clientMessageId: queued.clientMessageId)
            throw OutgoingMessageWriterError.missingClientProvider
        }

        let xmtpMessageId: String
        if let replyContext = queued.replyContext {
            let reply = Reply(reference: replyContext.parentDbId, content: queued.text, contentType: ContentTypeText)
            xmtpMessageId = try await sender.prepare(reply: reply)
        } else {
            xmtpMessageId = try await sender.prepare(text: queued.text)
        }
        Log.info("Text prepare() returned xmtpMessageId=\(xmtpMessageId), clientMessageId=\(queued.clientMessageId), same=\(xmtpMessageId == queued.clientMessageId)")

        if xmtpMessageId != queued.clientMessageId {
            try await databaseWriter.write { db in
                // Atomic primary key update - avoids the DELETE/INSERT pattern that causes message flash
                try db.execute(
                    sql: "UPDATE message SET id = ? WHERE id = ?",
                    arguments: [xmtpMessageId, queued.clientMessageId]
                )
                // Update any messages that reference this one via sourceMessageId
                try db.execute(
                    sql: "UPDATE message SET sourceMessageId = ? WHERE sourceMessageId = ?",
                    arguments: [xmtpMessageId, queued.clientMessageId]
                )
                Log.info("Updated text message id from \(queued.clientMessageId) to \(xmtpMessageId)")
            }
        }

        do {
            try await sender.publish()
            try await markMessagePublished(messageId: xmtpMessageId)
            sentMessageSubject.send(queued.text)
            Log.info("Published text message with id: \(xmtpMessageId)")
        } catch {
            Log.error("Failed publishing text message: \(error)")
            try? await markMessageFailed(messageId: xmtpMessageId)
            throw error
        }
    }

    private func publishPhoto(_ queued: QueuedPhotoMessage) async throws {
        let trackingKey = queued.localCacheURL.absoluteString
        let tracker = PhotoUploadProgressTracker.shared

        tracker.setStage(.preparing, for: trackingKey)

        let inboxReady = try await inboxStateManager.waitForInboxReadyResult()

        let prepared: PreparedBackgroundUpload
        do {
            prepared = try await photoService.prepareForBackgroundUpload(
                image: queued.image,
                apiClient: inboxReady.apiClient,
                filename: queued.filename
            )
        } catch {
            tracker.setStage(.failed, for: trackingKey)
            try? await markMessageFailed(clientMessageId: queued.clientMessageId)
            throw error
        }

        let pendingUpload = DBPendingPhotoUpload(
            id: prepared.taskId,
            clientMessageId: queued.clientMessageId,
            conversationId: conversationId,
            localCacheURL: queued.localCacheURL.absoluteString,
            state: .uploading
        )
        try await pendingUploadWriter.create(pendingUpload)

        tracker.setProgress(stage: .uploading, percentage: 0, for: trackingKey)

        do {
            try await backgroundUploadManager.startUpload(
                fileURL: prepared.encryptedFileURL,
                uploadURL: prepared.presignedUploadURL,
                contentType: "application/octet-stream",
                taskId: prepared.taskId
            )
        } catch {
            tracker.setStage(.failed, for: trackingKey)
            try await pendingUploadWriter.updateState(
                taskId: prepared.taskId,
                state: .failed,
                errorMessage: error.localizedDescription
            )
            try? await markMessageFailed(clientMessageId: queued.clientMessageId)
            throw error
        }

        // Wait for this specific upload to complete using dedicated per-task completion tracking
        let result = await backgroundUploadManager.waitForCompletion(taskId: prepared.taskId)

        if result.success {
            try await pendingUploadWriter.updateState(taskId: prepared.taskId, state: .sending, errorMessage: nil)
        } else {
            tracker.setStage(.failed, for: trackingKey)
            try await pendingUploadWriter.updateState(
                taskId: prepared.taskId,
                state: .failed,
                errorMessage: result.error?.localizedDescription
            )
            try? await markMessageFailed(clientMessageId: queued.clientMessageId)
            throw result.error ?? PhotoAttachmentError.uploadFailed("Background upload failed")
        }

        tracker.setStage(.publishing, for: trackingKey)
        try await completeXMTPSend(
            queued: queued,
            prepared: prepared,
            trackingKey: trackingKey,
            inboxReady: inboxReady
        )
    }

    private func completeXMTPSend(
        queued: QueuedPhotoMessage,
        prepared: PreparedBackgroundUpload,
        trackingKey: String,
        inboxReady: InboxReadyResult,
        replyContext: ReplyContext? = nil
    ) async throws {
        let tracker = PhotoUploadProgressTracker.shared

        guard let sender = try await inboxReady.client.messageSender(for: conversationId) else {
            tracker.setStage(.failed, for: trackingKey)
            try await pendingUploadWriter.updateState(
                taskId: prepared.taskId,
                state: .failed,
                errorMessage: "No message sender"
            )
            try? await markMessageFailed(clientMessageId: queued.clientMessageId)
            throw OutgoingMessageWriterError.missingClientProvider
        }

        do {
            let remoteAttachment = try RemoteAttachment(
                url: prepared.assetURL,
                contentDigest: prepared.contentDigest,
                secret: prepared.encryptionSecret,
                salt: prepared.encryptionSalt,
                nonce: prepared.encryptionNonce,
                scheme: .https,
                contentLength: nil,
                filename: prepared.filename
            )

            let xmtpMessageId: String
            if let replyContext {
                let reply = Reply(reference: replyContext.parentDbId, content: remoteAttachment, contentType: ContentTypeRemoteAttachment)
                xmtpMessageId = try await sender.prepare(reply: reply)
            } else {
                xmtpMessageId = try await sender.prepare(remoteAttachment: remoteAttachment)
            }
            Log.info("Prepared photo message - XMTP id: \(xmtpMessageId), clientMessageId: \(queued.clientMessageId)")

            let storedAttachment = StoredRemoteAttachment(
                url: remoteAttachment.url,
                contentDigest: remoteAttachment.contentDigest,
                secret: remoteAttachment.secret,
                salt: remoteAttachment.salt,
                nonce: remoteAttachment.nonce,
                filename: remoteAttachment.filename
            )
            guard let storedJSON = try? storedAttachment.toJSON() else {
                tracker.setStage(.failed, for: trackingKey)
                try await pendingUploadWriter.updateState(
                    taskId: prepared.taskId,
                    state: .failed,
                    errorMessage: "JSON encoding failed"
                )
                throw PhotoAttachmentError.encryptionFailed
            }

            ImageCacheContainer.shared.cacheImage(queued.image, for: storedJSON)

            // Encode attachmentUrls as JSON (matches GRDB's Codable encoding for [String])
            let attachmentUrlsJSON = try JSONEncoder().encode([storedJSON])
            let attachmentUrlsString = String(data: attachmentUrlsJSON, encoding: .utf8) ?? "[]"

            let oldAttachmentKey = queued.localCacheURL.absoluteString
            Log.info("[OutgoingMessageWriter] About to update DB. Old key: \(oldAttachmentKey.prefix(60))...")
            Log.info("[OutgoingMessageWriter] New key (storedJSON): \(storedJSON.prefix(80))...")

            try await databaseWriter.write { db in
                // Atomic update - change primary key and attachment URL in one transaction
                // This avoids the DELETE/INSERT pattern that causes message flash
                try db.execute(
                    sql: """
                        UPDATE message
                        SET id = ?, attachmentUrls = ?
                        WHERE id = ?
                        """,
                    arguments: [xmtpMessageId, attachmentUrlsString, queued.clientMessageId]
                )
                // Update any messages that reference this one via sourceMessageId
                try db.execute(
                    sql: "UPDATE message SET sourceMessageId = ? WHERE sourceMessageId = ?",
                    arguments: [xmtpMessageId, queued.clientMessageId]
                )
                Log.info("Updated photo message - id: \(xmtpMessageId), clientMessageId: \(queued.clientMessageId)")
            }

            // Migrate the attachment local state (dimensions, reveal status) from the local file:// key
            // to the new remote attachment JSON key so dimensions are preserved after upload
            try await attachmentLocalStateWriter.migrateKey(from: oldAttachmentKey, to: storedJSON)

            try await sender.publish()
            try await markMessagePublished(messageId: xmtpMessageId)
            Log.info("Published photo message with id: \(xmtpMessageId)")

            try await pendingUploadWriter.delete(taskId: prepared.taskId)
            try? FileManager.default.removeItem(at: prepared.encryptedFileURL)

            tracker.setStage(.completed, for: trackingKey)
            sentMessageSubject.send(storedJSON)

            // Release any text messages that were waiting for this photo
            markPhotoPublished(trackingKey: trackingKey)
        } catch {
            tracker.setStage(.failed, for: trackingKey)
            Log.error("Failed publishing photo message: \(error)")
            try await pendingUploadWriter.updateState(
                taskId: prepared.taskId,
                state: .failed,
                errorMessage: error.localizedDescription
            )
            try? await markMessageFailed(clientMessageId: queued.clientMessageId)
            throw error
        }
    }

    // MARK: - Status Updates

    private func markMessagePublished(messageId: String) async throws {
        try await databaseWriter.write { db in
            guard let message = try DBMessage.fetchOne(db, key: messageId) else {
                Log.warning("markMessagePublished: message not found for id \(messageId)")
                return
            }
            let updated = message.with(status: .published)
            try updated.save(db)
            Log.info("Marked message as published: \(messageId) dateNs=\(updated.dateNs)")
        }
    }

    private func markMessageFailed(messageId: String) async throws {
        try await databaseWriter.write { db in
            guard let message = try DBMessage.fetchOne(db, key: messageId) else { return }
            try message.with(status: .failed).save(db)
        }
    }

    private func markMessageFailed(clientMessageId: String) async throws {
        try await databaseWriter.write { db in
            guard let message = try DBMessage
                .filter(DBMessage.Columns.clientMessageId == clientMessageId)
                .fetchOne(db) else { return }
            try message.with(status: .failed).save(db)
        }
    }

    // MARK: - Dependency Management

    private func markPhotoPublished(trackingKey: String) {
        publishedPhotoKeys.insert(trackingKey)

        // Move any texts that were waiting for this photo to the FRONT of the queue
        // so they get processed immediately after their photo, maintaining correct order
        let released = pendingTexts.filter { $0.dependsOnPhotoKey == trackingKey }
        pendingTexts.removeAll { $0.dependsOnPhotoKey == trackingKey }

        // Insert at front in reverse order so they end up in the correct order
        for text in released.reversed() {
            messageQueue.insert(.text(text), at: 0)
            Log.info("Released text message \(text.clientMessageId) after photo \(trackingKey) published (inserted at front)")
        }

        // Continue processing if we released any texts
        if !released.isEmpty {
            startProcessingIfNeeded()
        }
    }
}
