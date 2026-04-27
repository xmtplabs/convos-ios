import AVFoundation
import Combine
import ConvosMessagingProtocols
import Foundation
import GRDB
import UniformTypeIdentifiers

// The XIP send flow still lives on XMTPiOS (Reply, RemoteAttachment,
// Attachment, AttachmentCodec, ContentTypeText, ContentTypeRemoteAttachment,
// MessageSender.prepare(...)), so every XIP-layer call here routes
// through per-op bridges in
// `Messaging/Abstraction/XMTPiOSAdapter/DBBoundary/XMTPiOSConversationWriterSupport.swift`.
// This file itself stays Foundation + GRDB only.

public protocol OutgoingMessageWriterProtocol: Sendable {
    var sentMessage: AnyPublisher<String, Never> { get }
    func send(text: String) async throws
    func send(text: String, afterPhoto trackingKey: String?) async throws
    func send(image: ImageType) async throws
    func insertPendingInvite(text: String) async throws -> String
    func finalizeInvite(clientMessageId: String, finalText: String) async throws

    /// Start uploading a photo eagerly (before user taps Send).
    /// Returns a tracking key that can be used with `sendEagerPhoto` or `cancelEagerUpload`.
    func startEagerUpload(image: ImageType) async throws -> String

    /// Send a photo that was already started with `startEagerUpload`.
    /// Waits for upload to complete if still in progress, then sends via XMTP.
    func sendEagerPhoto(trackingKey: String) async throws

    /// Cancel an eager upload that was started but not sent.
    func cancelEagerUpload(trackingKey: String) async

    // MARK: - Replies

    /// Send a video from a local file URL.
    /// Returns a tracking key for dependency management.
    func sendVideo(at fileURL: URL, replyToMessageId: String?) async throws -> String

    /// Send a voice memo from a local audio file URL.
    func sendVoiceMemo(at fileURL: URL, duration: TimeInterval, waveformLevels: [Float]?, replyToMessageId: String?) async throws -> String

    /// Send a text reply to an existing message.
    func sendReply(text: String, toMessageWithClientId parentClientMessageId: String) async throws

    /// Send a photo reply that was already started with `startEagerUpload`.
    func sendEagerPhotoReply(trackingKey: String, toMessageWithClientId parentClientMessageId: String) async throws

    /// Send text after a photo reply (both replying to the same parent).
    func sendReply(text: String, afterPhoto trackingKey: String?, toMessageWithClientId parentClientMessageId: String) async throws

    // MARK: - Failed Messages

    func retryFailedMessage(id: String) async throws
    func deleteFailedMessage(id: String) async throws
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
        let isExistingLocalMessage: Bool
    }

    private struct QueuedPhotoMessage {
        let clientMessageId: String
        let image: ImageType
        let localCacheURL: URL
        let filename: String
        var replyContext: ReplyContext?
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

    private struct QueuedVideoMessage {
        let clientMessageId: String
        let localCacheURL: URL
        let filename: String
        let trackingKey: String
        var replyContext: ReplyContext?
    }

    private struct QueuedAudioMessage {
        let clientMessageId: String
        let localCacheURL: URL
        let filename: String
        let trackingKey: String
        let mimeType: String
        let duration: Double?
        var replyContext: ReplyContext?
    }

    private struct QueuedEagerPhoto {
        let trackingKey: String
    }

    private enum QueuedMessage {
        case text(QueuedTextMessage)
        case photo(QueuedPhotoMessage)
        case video(QueuedVideoMessage)
        case audio(QueuedAudioMessage)
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

    func insertPendingInvite(text: String) async throws -> String {
        let clientMessageId = UUID().uuidString
        try await saveTextToDatabase(clientMessageId: clientMessageId, text: text, replyContext: nil)
        return clientMessageId
    }

    func finalizeInvite(clientMessageId: String, finalText: String) async throws {
        let didUpdateMessage = try await databaseWriter.write { db in
            guard var message = try DBMessage
                .filter(DBMessage.Columns.clientMessageId == clientMessageId)
                .fetchOne(db) else {
                return false
            }
            let invite = MessageInvite.from(text: finalText)
            message = message.with(text: finalText, invite: invite)
            try message.update(db)
            return true
        }
        guard didUpdateMessage else {
            Log.warning("Skipping finalizeInvite queueing for missing message: \(clientMessageId)")
            return
        }
        let queued = QueuedTextMessage(
            clientMessageId: clientMessageId,
            text: finalText,
            dependsOnPhotoKey: nil,
            replyContext: nil,
            isExistingLocalMessage: true
        )
        messageQueue.append(.text(queued))
        startProcessingIfNeeded()
    }

    private func sendText(_ text: String, afterPhoto trackingKey: String?, replyContext: ReplyContext?) async throws {
        let clientMessageId = UUID().uuidString
        try await saveTextToDatabase(clientMessageId: clientMessageId, text: text, replyContext: replyContext)

        let queued = QueuedTextMessage(
            clientMessageId: clientMessageId,
            text: text,
            dependsOnPhotoKey: trackingKey,
            replyContext: replyContext,
            isExistingLocalMessage: false
        )

        // If this text depends on a photo that hasn't been published yet, defer it
        if let photoKey = trackingKey, !publishedPhotoKeys.contains(photoKey) {
            pendingTexts.append(queued)
            Log.debug("Text message \(clientMessageId) deferred, waiting for photo \(photoKey)")
        } else {
            messageQueue.append(.text(queued))
            startProcessingIfNeeded()
        }
    }

    func send(image: ImageType) async throws {
        let clientMessageId = UUID().uuidString
        let filename = photoService.generateFilename()
        let localCacheURL = try photoService.localCacheURL(for: filename)

        ImageCacheContainer.shared.cacheImage(image, for: localCacheURL.absoluteString, storageTier: .persistent)

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
        let localCacheURL = try photoService.localCacheURL(for: filename)
        let trackingKey = localCacheURL.absoluteString

        Log.debug("Starting eager upload for trackingKey: \(trackingKey)")

        // Cache the image but do NOT save to database yet - that happens when user taps Send
        ImageCacheContainer.shared.cacheImage(image, for: trackingKey, storageTier: .persistent)

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

        Log.debug("handleUploadCompletion: Received result for taskId: \(taskId), success: \(result.success)")

        if result.success {
            try? await pendingUploadWriter.updateState(taskId: taskId, state: .sending, errorMessage: nil)
            if var state = eagerUploads[trackingKey] {
                state.uploadCompleted = true
                let continuation = state.waitingContinuation
                state.waitingContinuation = nil
                eagerUploads[trackingKey] = state
                Log.debug("handleUploadCompletion: Upload succeeded, has continuation: \(continuation != nil)")
                continuation?.resume()
            } else {
                Log.warning("handleUploadCompletion: No state found for trackingKey: \(trackingKey)")
            }
            Log.debug("Eager upload completed successfully for: \(trackingKey)")
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
            await markPhotoFailed(trackingKey: trackingKey)
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
            Log.debug("processEagerPhoto: Upload not complete, waiting for continuation...")
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                state.waitingContinuation = continuation
                eagerUploads[trackingKey] = state
                Log.debug("processEagerPhoto: Continuation stored, suspending...")
            }
            Log.debug("processEagerPhoto: Continuation resumed!")
            guard let updatedState = eagerUploads[trackingKey] else {
                throw OutgoingMessageWriterError.eagerUploadNotFound
            }
            state = updatedState
        } else {
            Log.debug("processEagerPhoto: Upload already complete, proceeding immediately")
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

        Log.debug("Cancelling eager upload for: \(trackingKey)")

        await backgroundUploadManager.cancelUpload(taskId: state.prepared.taskId)

        try? await pendingUploadWriter.delete(taskId: state.prepared.taskId)
        try? FileManager.default.removeItem(at: state.prepared.encryptedFileURL)

        // Note: No need to delete from DBMessage - the message was never saved to the database
        // (that only happens in sendEagerPhoto when user taps Send)

        PhotoUploadProgressTracker.shared.clear(key: trackingKey)

        await markPhotoFailed(trackingKey: trackingKey)
        eagerUploads.removeValue(forKey: trackingKey)
    }

    // MARK: - File Attachment Upload (shared by video, voice memo, and future types)

    struct AttachmentUploadParams {
        let dataURL: URL
        let filename: String
        let mimeType: String
        var width: Int?
        var height: Int?
        var duration: Double?
        var thumbnailData: Data?
        var waveformLevels: [Float]?
        var mediaTypeLabel: String = "attachment"
    }

    private func sendFileAttachment(
        params: AttachmentUploadParams,
        replyToMessageId: String?
    ) async throws -> String {
        let clientMessageId = UUID().uuidString
        let localCacheURL = try photoService.localCacheURL(for: params.filename)

        try FileManager.default.createDirectory(
            at: localCacheURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try FileManager.default.copyItem(at: params.dataURL, to: localCacheURL)

        let trackingKey = localCacheURL.absoluteString

        if let thumbnailData = params.thumbnailData, let thumbnailImage = ImageType(data: thumbnailData) {
            ImageCacheContainer.shared.cacheImage(thumbnailImage, for: trackingKey, storageTier: .persistent)
        }

        try await attachmentLocalStateWriter.saveWithDimensions(
            attachmentKey: trackingKey,
            conversationId: conversationId,
            width: params.width ?? 0,
            height: params.height ?? 0,
            mimeType: params.mimeType
        )

        if let waveformLevels = params.waveformLevels {
            try? await attachmentLocalStateWriter.saveWaveformLevels(waveformLevels, for: trackingKey)
        }

        if let duration = params.duration {
            try? await attachmentLocalStateWriter.saveDuration(duration, for: trackingKey)
        }

        var replyContext: ReplyContext?
        if let replyToMessageId {
            replyContext = try await resolveReplyContext(parentClientMessageId: replyToMessageId)
        }

        try await savePhotoToDatabase(clientMessageId: clientMessageId, localCacheURL: localCacheURL, replyContext: replyContext)

        let tracker = PhotoUploadProgressTracker.shared
        tracker.setStage(.preparing, for: trackingKey)

        do {
            let inboxReady = try await inboxStateManager.waitForInboxReadyResult()

            let fileData = try Data(contentsOf: params.dataURL)
            // Delegate Attachment + AttachmentCodec construction to the
            // XIP bridge — these codecs still live in the XMTPiOS layer.
            let encrypted = try encodeEncryptedAttachmentViaBridge(
                filename: params.filename,
                mimeType: params.mimeType,
                data: fileData
            )

            let presignedURLs = try await inboxReady.apiClient.getPresignedUploadURL(
                filename: params.filename,
                contentType: "application/octet-stream"
            )

            guard let uploadURL = URL(string: presignedURLs.uploadURL) else {
                throw PhotoAttachmentError.invalidURL
            }

            let taskId = UUID().uuidString
            let encryptedFileURL = try saveToTemp(data: encrypted.payload, taskId: taskId)
            defer { try? FileManager.default.removeItem(at: encryptedFileURL) }

            tracker.setProgress(stage: .uploading, percentage: 0, for: trackingKey)

            try await backgroundUploadManager.startUpload(
                fileURL: encryptedFileURL,
                uploadURL: uploadURL,
                contentType: "application/octet-stream",
                taskId: taskId
            )

            let result = await backgroundUploadManager.waitForCompletion(taskId: taskId)

            guard result.success else {
                tracker.setStage(.failed, for: trackingKey)
                try? await markMessageFailed(clientMessageId: clientMessageId)
                throw result.error ?? PhotoAttachmentError.uploadFailed("\(params.mediaTypeLabel) upload failed")
            }

            tracker.setStage(.publishing, for: trackingKey)

            let storedAttachment = StoredRemoteAttachment(
                url: presignedURLs.assetURL,
                contentDigest: encrypted.digest,
                secret: encrypted.secret,
                salt: encrypted.salt,
                nonce: encrypted.nonce,
                filename: params.filename,
                mimeType: params.mimeType,
                mediaWidth: params.width,
                mediaHeight: params.height,
                mediaDuration: params.duration,
                thumbnailDataBase64: params.thumbnailData?.base64EncodedString()
            )

            let messageId = try await publishAttachment(
                storedAttachment: storedAttachment,
                clientMessageId: clientMessageId,
                trackingKey: trackingKey,
                thumbnailImage: params.thumbnailData.flatMap { ImageType(data: $0) },
                inboxReady: inboxReady,
                replyContext: replyContext,
                mediaType: params.mediaTypeLabel
            )

            QAEvent.emit(.message, "sent", ["id": messageId, "conversation": conversationId, "type": params.mediaTypeLabel])

            return trackingKey
        } catch {
            tracker.setStage(.failed, for: trackingKey)
            try? await markMessageFailed(clientMessageId: clientMessageId)
            throw error
        }
    }

    // MARK: - Video

    func sendVideo(at fileURL: URL, replyToMessageId: String? = nil) async throws -> String {
        let compressionService = VideoCompressionService()
        let compressed = try await compressionService.compressVideo(at: fileURL)
        defer { try? FileManager.default.removeItem(at: compressed.fileURL) }

        let params = AttachmentUploadParams(
            dataURL: compressed.fileURL,
            filename: "video_\(Int(Date().timeIntervalSince1970))_\(UUID().uuidString.prefix(8)).mp4",
            mimeType: "video/mp4",
            width: compressed.width,
            height: compressed.height,
            duration: compressed.duration,
            thumbnailData: compressed.thumbnail,
            mediaTypeLabel: "video"
        )

        return try await sendFileAttachment(params: params, replyToMessageId: replyToMessageId)
    }

    private func publishAttachment(
        storedAttachment: StoredRemoteAttachment,
        clientMessageId: String,
        trackingKey: String,
        thumbnailImage: ImageType?,
        inboxReady: InboxReadyResult,
        replyContext: ReplyContext? = nil,
        mediaType: String = "photo"
    ) async throws -> String {
        let tracker = PhotoUploadProgressTracker.shared

        guard let json = try? storedAttachment.toJSON() else {
            tracker.setStage(.failed, for: trackingKey)
            throw PhotoAttachmentError.encryptionFailed
        }

        // `prepareRemoteAttachmentViaBridge` accepts `MessagingConversation`
        // and downcasts to the XMTPiOS adapter SDK-side.
        guard let conversation = try await inboxReady.client.messagingConversation(
            with: conversationId
        ) else {
            tracker.setStage(.failed, for: trackingKey)
            try? await markMessageFailed(clientMessageId: clientMessageId)
            throw OutgoingMessageWriterError.missingClientProvider
        }

        do {
            // RemoteAttachment + Reply construction and the prepare
            // dispatch live on the XIP bridge because the codecs still
            // live in the XMTPiOS layer.
            let messageId = try await prepareRemoteAttachmentViaBridge(
                conversation: conversation,
                stored: storedAttachment,
                replyParentDbId: replyContext?.parentDbId
            )

            if let thumbnailImage {
                ImageCacheContainer.shared.cacheImage(thumbnailImage, for: json, storageTier: .persistent)
            }

            let attachmentUrlsJSON = try JSONEncoder().encode([json])
            let attachmentUrlsString = String(data: attachmentUrlsJSON, encoding: .utf8) ?? "[]"

            try await databaseWriter.write { db in
                try db.execute(
                    sql: """
                        UPDATE message
                        SET id = ?, attachmentUrls = ?
                        WHERE id = ?
                        """,
                    arguments: [messageId, attachmentUrlsString, clientMessageId]
                )
                try db.execute(
                    sql: "UPDATE message SET sourceMessageId = ? WHERE sourceMessageId = ?",
                    arguments: [messageId, clientMessageId]
                )
            }

            try await attachmentLocalStateWriter.migrateKey(from: trackingKey, to: json)

            // `MessagingConversationCore.publish()` publishes every
            // unpublished message on the conversation.
            try await conversation.core.publish()

            ImageCacheContainer.shared.removeImage(for: trackingKey)

            try? await markMessagePublished(messageId: messageId)
            tracker.setStage(.completed, for: trackingKey)
            sentMessageSubject.send(json)
            markPhotoPublished(trackingKey: trackingKey)

            return messageId
        } catch {
            tracker.setStage(.failed, for: trackingKey)
            try? await markMessageFailed(clientMessageId: clientMessageId)
            throw error
        }
    }

    private func saveToTemp(data: Data, taskId: String) throws -> URL {
        let tempDir = FileManager.default.temporaryDirectory
        let fileURL = tempDir.appendingPathComponent("\(taskId).enc")
        try data.write(to: fileURL)
        return fileURL
    }

    // MARK: - Voice Memo

    func sendVoiceMemo(at fileURL: URL, duration: TimeInterval, waveformLevels: [Float]? = nil, replyToMessageId: String? = nil) async throws -> String {
        let params = AttachmentUploadParams(
            dataURL: fileURL,
            filename: "voice_memo_\(Int(Date().timeIntervalSince1970))_\(UUID().uuidString.prefix(8)).m4a",
            mimeType: "audio/m4a",
            duration: duration,
            waveformLevels: waveformLevels,
            mediaTypeLabel: "voice_memo"
        )

        return try await sendFileAttachment(params: params, replyToMessageId: replyToMessageId)
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
                case .video(let queued):
                    try await publishVideo(queued)
                case .audio(let queued):
                    try await publishAudio(queued)
                case .eagerPhoto(let queued):
                    try await processEagerPhoto(trackingKey: queued.trackingKey)
                }
            } catch {
                switch message {
                case .photo(let queued):
                    await markPhotoFailed(trackingKey: queued.localCacheURL.absoluteString)
                case .video(let queued):
                    await markPhotoFailed(trackingKey: queued.trackingKey)
                case .audio(let queued):
                    await markPhotoFailed(trackingKey: queued.trackingKey)
                case .eagerPhoto(let queued):
                    await markPhotoFailed(trackingKey: queued.trackingKey)
                case .text:
                    break
                }
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
        let linkPreview = invite == nil && !isContentEmoji ? LinkPreview.from(text: text) : nil

        let contentType: MessageContentType
        if isContentEmoji {
            contentType = .emoji
        } else if invite != nil {
            contentType = .invite
        } else if linkPreview != nil {
            contentType = .linkPreview
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
                linkPreview: linkPreview,
                sourceMessageId: replyContext?.parentDbId,
                attachmentUrls: [],
                update: nil
            )
            try localMessage.save(db)
            Log.debug("Saved text message optimistically with id: \(clientMessageId) sortId=\(sortId)")
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
                linkPreview: nil,
                sourceMessageId: replyContext?.parentDbId,
                attachmentUrls: [localCacheURL.absoluteString],
                update: nil
            )
            try localMessage.save(db)
            Log.debug("Saved photo message optimistically with clientMessageId: \(clientMessageId) sortId=\(sortId)")
        }
    }

    // MARK: - Network Publishing (Sequential)

    private func publishText(_ queued: QueuedTextMessage) async throws {
        let perfStart = CFAbsoluteTimeGetCurrent()
        let inboxReady = try await inboxStateManager.waitForInboxReadyResult()
        // The text-prepare and text-reply-prepare paths still need an
        // XMTPiOS-side codec, so they go through `MessagingWriterBridge`
        // (which downcasts to the XMTPiOS adapter SDK-side).
        guard let conversation = try await inboxReady.client.messagingConversation(
            with: conversationId
        ) else {
            try? await markMessageFailed(clientMessageId: queued.clientMessageId)
            throw OutgoingMessageWriterError.missingClientProvider
        }

        let xmtpMessageId: String
        if let replyContext = queued.replyContext {
            xmtpMessageId = try await prepareTextReplyViaBridge(
                conversation: conversation,
                text: queued.text,
                replyParentDbId: replyContext.parentDbId
            )
        } else {
            xmtpMessageId = try await prepareTextViaBridge(
                conversation: conversation,
                text: queued.text
            )
        }
        Log.debug("Text prepare() returned xmtpMessageId=\(xmtpMessageId), clientMessageId=\(queued.clientMessageId), same=\(xmtpMessageId == queued.clientMessageId)")

        try await databaseWriter.write { db in
            guard let message = try DBMessage
                .filter(DBMessage.Columns.clientMessageId == queued.clientMessageId)
                .fetchOne(db) else {
                Log.warning("publishText: message not found for clientMessageId \(queued.clientMessageId)")
                return
            }

            if queued.isExistingLocalMessage {
                try db.execute(
                    sql: "UPDATE message SET id = ?, status = ? WHERE id = ?",
                    arguments: [xmtpMessageId, MessageStatus.unpublished.rawValue, message.id]
                )
                try db.execute(
                    sql: "UPDATE message SET sourceMessageId = ? WHERE sourceMessageId = ?",
                    arguments: [xmtpMessageId, queued.clientMessageId]
                )
                Log.debug("Updated existing local text message id from \(queued.clientMessageId) to \(xmtpMessageId)")
                return
            }

            if xmtpMessageId != queued.clientMessageId {
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
                Log.debug("Updated text message id from \(queued.clientMessageId) to \(xmtpMessageId)")
            }
        }

        do {
            // `MessagingConversationCore.publish()` publishes every
            // unpublished message on the conversation.
            try await conversation.core.publish()
        } catch {
            Log.error("Failed publishing text message: \(error)")
            try? await markMessageFailed(messageId: xmtpMessageId)
            throw error
        }

        do {
            try await markMessagePublished(messageId: xmtpMessageId)
        } catch {
            Log.error("Failed to update message status after successful publish: \(error)")
        }
        sentMessageSubject.send(queued.text)
        let perfElapsed = String(format: "%.0f", (CFAbsoluteTimeGetCurrent() - perfStart) * 1000)
        Log.info("[PERF] message.publish_text: \(perfElapsed)ms id=\(xmtpMessageId)")
        QAEvent.emit(.message, "sent", ["id": xmtpMessageId, "conversation": conversationId, "type": "text"])
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
            inboxReady: inboxReady,
            replyContext: queued.replyContext
        )
    }

    private func publishVideo(_ queued: QueuedVideoMessage) async throws {
        let tracker = PhotoUploadProgressTracker.shared
        tracker.setStage(.preparing, for: queued.trackingKey)

        let inboxReady = try await inboxStateManager.waitForInboxReadyResult()

        let videoData = try Data(contentsOf: queued.localCacheURL)
        let encrypted = try encodeEncryptedAttachmentViaBridge(
            filename: queued.filename,
            mimeType: "video/mp4",
            data: videoData
        )

        let presignedURLs = try await inboxReady.apiClient.getPresignedUploadURL(
            filename: queued.filename,
            contentType: "application/octet-stream"
        )

        guard let uploadURL = URL(string: presignedURLs.uploadURL) else {
            tracker.setStage(.failed, for: queued.trackingKey)
            try? await markMessageFailed(clientMessageId: queued.clientMessageId)
            throw PhotoAttachmentError.invalidURL
        }

        let taskId = UUID().uuidString
        let encryptedFileURL = try saveToTemp(data: encrypted.payload, taskId: taskId)

        tracker.setProgress(stage: .uploading, percentage: 0, for: queued.trackingKey)

        try await backgroundUploadManager.startUpload(
            fileURL: encryptedFileURL,
            uploadURL: uploadURL,
            contentType: "application/octet-stream",
            taskId: taskId
        )

        let result = await backgroundUploadManager.waitForCompletion(taskId: taskId)

        guard result.success else {
            tracker.setStage(.failed, for: queued.trackingKey)
            try? await markMessageFailed(clientMessageId: queued.clientMessageId)
            throw result.error ?? PhotoAttachmentError.uploadFailed("Video upload failed")
        }

        tracker.setStage(.publishing, for: queued.trackingKey)

        let thumbnailImage = ImageCacheContainer.shared.image(for: queued.trackingKey)

        let storedAttachment = StoredRemoteAttachment(
            url: presignedURLs.assetURL,
            contentDigest: encrypted.digest,
            secret: encrypted.secret,
            salt: encrypted.salt,
            nonce: encrypted.nonce,
            filename: queued.filename,
            mimeType: "video/mp4",
            mediaWidth: nil,
            mediaHeight: nil,
            mediaDuration: nil,
            thumbnailDataBase64: thumbnailImage.flatMap { $0.crossPlatformJPEGData(compressionQuality: 0.5)?.base64EncodedString() }
        )

        let messageId = try await publishAttachment(
            storedAttachment: storedAttachment,
            clientMessageId: queued.clientMessageId,
            trackingKey: queued.trackingKey,
            thumbnailImage: thumbnailImage,
            inboxReady: inboxReady,
            replyContext: queued.replyContext,
            mediaType: "video"
        )

        try? FileManager.default.removeItem(at: encryptedFileURL)
        QAEvent.emit(.message, "sent", ["id": messageId, "conversation": conversationId, "type": "video_retry"])
    }

    private func publishAudio(_ queued: QueuedAudioMessage) async throws {
        let tracker = PhotoUploadProgressTracker.shared
        tracker.setStage(.preparing, for: queued.trackingKey)

        let inboxReady = try await inboxStateManager.waitForInboxReadyResult()

        let audioData = try Data(contentsOf: queued.localCacheURL)
        let encrypted = try encodeEncryptedAttachmentViaBridge(
            filename: queued.filename,
            mimeType: queued.mimeType,
            data: audioData
        )

        let presignedURLs = try await inboxReady.apiClient.getPresignedUploadURL(
            filename: queued.filename,
            contentType: "application/octet-stream"
        )

        guard let uploadURL = URL(string: presignedURLs.uploadURL) else {
            tracker.setStage(.failed, for: queued.trackingKey)
            try? await markMessageFailed(clientMessageId: queued.clientMessageId)
            throw PhotoAttachmentError.invalidURL
        }

        let taskId = UUID().uuidString
        let encryptedFileURL = try saveToTemp(data: encrypted.payload, taskId: taskId)

        tracker.setProgress(stage: .uploading, percentage: 0, for: queued.trackingKey)

        try await backgroundUploadManager.startUpload(
            fileURL: encryptedFileURL,
            uploadURL: uploadURL,
            contentType: "application/octet-stream",
            taskId: taskId
        )

        let result = await backgroundUploadManager.waitForCompletion(taskId: taskId)

        guard result.success else {
            tracker.setStage(.failed, for: queued.trackingKey)
            try? await markMessageFailed(clientMessageId: queued.clientMessageId)
            throw result.error ?? PhotoAttachmentError.uploadFailed("Audio upload failed")
        }

        tracker.setStage(.publishing, for: queued.trackingKey)

        let storedAttachment = StoredRemoteAttachment(
            url: presignedURLs.assetURL,
            contentDigest: encrypted.digest,
            secret: encrypted.secret,
            salt: encrypted.salt,
            nonce: encrypted.nonce,
            filename: queued.filename,
            mimeType: queued.mimeType,
            mediaWidth: nil,
            mediaHeight: nil,
            mediaDuration: queued.duration,
            thumbnailDataBase64: nil
        )

        let messageId = try await publishAttachment(
            storedAttachment: storedAttachment,
            clientMessageId: queued.clientMessageId,
            trackingKey: queued.trackingKey,
            thumbnailImage: nil,
            inboxReady: inboxReady,
            replyContext: queued.replyContext,
            mediaType: "voice_memo"
        )

        try? FileManager.default.removeItem(at: encryptedFileURL)
        QAEvent.emit(.message, "sent", ["id": messageId, "conversation": conversationId, "type": "voice_memo_retry"])
    }

    private func completeXMTPSend(
        queued: QueuedPhotoMessage,
        prepared: PreparedBackgroundUpload,
        trackingKey: String,
        inboxReady: InboxReadyResult,
        replyContext: ReplyContext? = nil
    ) async throws {
        let perfStart = CFAbsoluteTimeGetCurrent()

        let storedAttachment = StoredRemoteAttachment(
            url: prepared.assetURL,
            contentDigest: prepared.contentDigest,
            secret: prepared.encryptionSecret,
            salt: prepared.encryptionSalt,
            nonce: prepared.encryptionNonce,
            filename: prepared.filename
        )

        let messageId: String
        do {
            messageId = try await publishAttachment(
                storedAttachment: storedAttachment,
                clientMessageId: queued.clientMessageId,
                trackingKey: trackingKey,
                thumbnailImage: queued.image,
                inboxReady: inboxReady,
                replyContext: replyContext
            )
        } catch {
            Log.error("Failed publishing photo message: \(error)")
            try? await pendingUploadWriter.updateState(
                taskId: prepared.taskId,
                state: .failed,
                errorMessage: error.localizedDescription
            )
            throw error
        }

        let perfElapsed = String(format: "%.0f", (CFAbsoluteTimeGetCurrent() - perfStart) * 1000)
        Log.info("[PERF] message.publish_photo: \(perfElapsed)ms id=\(messageId)")
        QAEvent.emit(.message, "sent", ["id": messageId, "conversation": conversationId, "type": "photo"])

        try? await pendingUploadWriter.delete(taskId: prepared.taskId)
        try? FileManager.default.removeItem(at: prepared.encryptedFileURL)
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
            Log.debug("Marked message as published: \(messageId) dateNs=\(updated.dateNs)")
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
            Log.debug("Released text message \(text.clientMessageId) after photo \(trackingKey) published (inserted at front)")
        }

        // Continue processing if we released any texts
        if !released.isEmpty {
            startProcessingIfNeeded()
        }
    }

    private func markPhotoFailed(trackingKey: String) async {
        let orphaned = pendingTexts.filter { $0.dependsOnPhotoKey == trackingKey }
        pendingTexts.removeAll { $0.dependsOnPhotoKey == trackingKey }

        for text in orphaned {
            Log.error("Marking dependent text \(text.clientMessageId) as failed after photo \(trackingKey) failed")
            try? await markMessageFailed(clientMessageId: text.clientMessageId)
        }
    }

    // MARK: - Failed Messages

    private var retryingMessageIds: Set<String> = []

    func retryFailedMessage(id clientMessageId: String) async throws {
        guard !retryingMessageIds.contains(clientMessageId) else {
            Log.debug("Retry already in progress for message \(clientMessageId), skipping")
            return
        }
        retryingMessageIds.insert(clientMessageId)
        defer { retryingMessageIds.remove(clientMessageId) }

        let message = try await databaseWriter.read { db in
            try DBMessage
                .filter(DBMessage.Columns.clientMessageId == clientMessageId)
                .fetchOne(db)
        }
        guard let message, message.status == .failed else { return }

        let replyContext: ReplyContext? = if let parentId = message.sourceMessageId {
            ReplyContext(parentDbId: parentId)
        } else {
            nil
        }

        if message.contentType == .attachments {
            try await retryFailedPhoto(message: message, replyContext: replyContext)
        } else {
            try await retryFailedText(message: message, replyContext: replyContext)
        }
    }

    private func retryFailedText(message: DBMessage, replyContext: ReplyContext?) async throws {
        let text = message.text ?? message.emoji ?? ""
        guard !text.isEmpty else { return }

        let wasPrepared = message.id != message.clientMessageId

        if wasPrepared {
            Log.debug("Message \(message.id) already prepared, publishing directly")
            try await databaseWriter.write { db in
                try message.with(status: .unpublished).save(db)
            }
            try await publishPreparedMessage(messageId: message.id, sentContent: text)
        } else {
            try await databaseWriter.write { db in
                try message.with(status: .unpublished).save(db)
            }
            let queued = QueuedTextMessage(
                clientMessageId: message.clientMessageId,
                text: text,
                dependsOnPhotoKey: nil,
                replyContext: replyContext,
                isExistingLocalMessage: false
            )
            messageQueue.append(.text(queued))
            startProcessingIfNeeded()
        }
    }

    private func publishPreparedMessage(messageId: String, sentContent: String? = nil) async throws {
        let inboxReady = try await inboxStateManager.waitForInboxReadyResult()
        guard let conversation = try await inboxReady.client.messagingConversation(
            with: conversationId
        ) else {
            try? await markMessageFailed(messageId: messageId)
            throw OutgoingMessageWriterError.missingClientProvider
        }

        do {
            try await conversation.core.publish(messageId: messageId)
        } catch {
            Log.error("Failed publishing prepared message: \(error)")
            try? await markMessageFailed(messageId: messageId)
            throw error
        }

        try? await markMessagePublished(messageId: messageId)
        if let sentContent {
            sentMessageSubject.send(sentContent)
        }
    }

    private func retryFailedPhoto(message: DBMessage, replyContext: ReplyContext?) async throws {
        let wasPrepared = message.id != message.clientMessageId
        if wasPrepared {
            Log.debug("Photo \(message.id) already prepared, publishing directly")
            try await databaseWriter.write { db in
                try message.with(status: .unpublished).save(db)
            }
            try await publishPreparedMessage(messageId: message.id, sentContent: message.attachmentUrls.first)
            return
        }

        guard let attachmentRef = message.attachmentUrls.first, !attachmentRef.isEmpty else {
            Log.error("Cannot retry photo: no attachment reference")
            return
        }

        let localFileURL: URL
        if attachmentRef.hasPrefix("{") {
            guard let localURL = resolveLocalCacheURL(from: attachmentRef) else {
                Log.error("Cannot retry photo: uploaded attachment has no local cache")
                return
            }
            localFileURL = localURL
        } else if let parsed = URL(string: attachmentRef) {
            localFileURL = parsed.scheme == "file" ? parsed : URL(fileURLWithPath: parsed.path)
        } else {
            Log.error("Cannot retry photo: invalid attachment reference")
            return
        }

        guard FileManager.default.fileExists(atPath: localFileURL.path) else {
            Log.error("Cannot retry attachment: local file no longer exists at \(localFileURL.path)")
            return
        }

        let localState = try await databaseWriter.read { db in
            try AttachmentLocalState
                .filter(AttachmentLocalState.Columns.attachmentKey == localFileURL.absoluteString)
                .fetchOne(db)
        }

        let mediaType = detectRetryMediaType(
            mimeType: localState?.mimeType,
            filename: localFileURL.lastPathComponent
        )

        try await databaseWriter.write { db in
            try message.with(status: .unpublished).save(db)
        }

        let filename = localFileURL.lastPathComponent
        let trackingKey = localFileURL.absoluteString

        switch mediaType {
        case .video:
            let queued = QueuedVideoMessage(
                clientMessageId: message.clientMessageId,
                localCacheURL: localFileURL,
                filename: filename,
                trackingKey: trackingKey,
                replyContext: replyContext
            )
            messageQueue.append(.video(queued))
        case .audio:
            let queued = QueuedAudioMessage(
                clientMessageId: message.clientMessageId,
                localCacheURL: localFileURL,
                filename: filename,
                trackingKey: trackingKey,
                mimeType: localState?.mimeType ?? "audio/m4a",
                duration: localState?.duration,
                replyContext: replyContext
            )
            messageQueue.append(.audio(queued))
        case .image, .unknown:
            guard let imageData = try? Data(contentsOf: localFileURL),
                  let image = ImageType(data: imageData) else {
                Log.error("Cannot retry photo: failed to load image from \(localFileURL.path)")
                return
            }

            let queued = QueuedPhotoMessage(
                clientMessageId: message.clientMessageId,
                image: image,
                localCacheURL: localFileURL,
                filename: filename,
                replyContext: replyContext
            )
            messageQueue.append(.photo(queued))
        case .file:
            Log.error("Cannot retry attachment: unsupported file type for \(localFileURL.path)")
            return
        }

        startProcessingIfNeeded()
    }

    private func detectRetryMediaType(mimeType: String?, filename: String?) -> MediaType {
        if let mimeType {
            if mimeType.hasPrefix("image/") { return .image }
            if mimeType.hasPrefix("video/") { return .video }
            if mimeType.hasPrefix("audio/") { return .audio }
            return .file
        }

        guard let filename else { return .unknown }
        let ext = (filename as NSString).pathExtension.lowercased()
        guard !ext.isEmpty, let utType = UTType(filenameExtension: ext) else { return .unknown }
        if utType.conforms(to: .image) { return .image }
        if utType.conforms(to: .movie) || utType.conforms(to: .video) { return .video }
        if utType.conforms(to: .audio) { return .audio }
        return .file
    }

    private func resolveLocalCacheURL(from storedJSON: String) -> URL? {
        guard let stored = try? StoredRemoteAttachment.fromJSON(storedJSON),
              let filename = stored.filename else {
            return nil
        }
        guard let url = try? photoService.localCacheURL(for: filename),
              FileManager.default.fileExists(atPath: url.path) else {
            return nil
        }
        return url
    }

    func deleteFailedMessage(id clientMessageId: String) async throws {
        try await databaseWriter.write { db in
            let deleted = try DBMessage
                .filter(DBMessage.Columns.clientMessageId == clientMessageId)
                .filter(DBMessage.Columns.status == MessageStatus.failed.rawValue)
                .deleteAll(db)
            if deleted == 0 {
                Log.warning("No failed message found to delete for clientMessageId: \(clientMessageId)")
            }
        }
    }
}
