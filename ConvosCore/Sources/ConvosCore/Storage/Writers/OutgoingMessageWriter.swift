import AVFoundation
import Combine
import Foundation
import GRDB
import UniformTypeIdentifiers
@preconcurrency import XMTPiOS

/// One entry in a `MultiRemoteAttachment` bundle. Eager photo/video variants
/// reference an upload that was already kicked off by the composer; voice
/// memo and file variants point at a local URL the writer encrypts + uploads
/// at send time. Used by the assistant builder so the whole batch — text +
/// photos + videos + voice memo + file — lands at the assistant as a single
/// delivery rather than a stream of independent messages.
public enum MultiAttachmentBundleItem: Sendable {
    case eagerPhoto(trackingKey: String)
    case eagerVideo(trackingKey: String)
    case voiceMemo(url: URL, duration: TimeInterval, waveformLevels: [Float])
    case file(url: URL, filename: String, mimeType: String)
}

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

    /// Start the compress-encrypt-upload pipeline for a video eagerly (before user
    /// taps Send). Returns a tracking key usable with `sendEagerVideo` /
    /// `sendEagerVideoReply` / `cancelEagerUpload`. The thumbnail and dimensions
    /// are captured synchronously so the bubble can render immediately on Send;
    /// compression and upload run in the background.
    func startEagerVideoUpload(at fileURL: URL) async throws -> String

    /// Send a video that was already started with `startEagerVideoUpload`.
    /// Waits for the background pipeline to finish if still in progress.
    func sendEagerVideo(trackingKey: String) async throws

    /// Send a video reply that was already started with `startEagerVideoUpload`.
    func sendEagerVideoReply(trackingKey: String, toMessageWithClientId parentClientMessageId: String) async throws

    /// Cancel an eager upload (photo or video) that was started but not sent.
    func cancelEagerUpload(trackingKey: String) async

    /// Await the completion of an eager photo or video upload that was started
    /// with `startEagerUpload` / `startEagerVideoUpload`. Returns immediately if
    /// the upload has already finished; throws the upload's error if it failed
    /// or `eagerUploadCancelled` if cancelled while waiting. Distinct from the
    /// single-shot continuation `processEagerPhoto` consumes when the queue
    /// finally flushes the send — multiple callers can wait concurrently
    /// without interfering with each other or with the send pipeline. Used by
    /// the assistant builder to gate its commit-time sends on every media
    /// upload finishing first, so the assistant receives the whole batch as a
    /// single delivery burst rather than trickling messages over the duration
    /// of the slowest upload.
    func awaitEagerUpload(trackingKey: String) async throws

    /// Send every entry in `items` as a single XMTP `MultiRemoteAttachment`
    /// message. Eager photo / video entries reuse their already-uploaded
    /// encrypted payload (no second upload); voice memo and file entries are
    /// encrypted and uploaded inline before the bundle is published. The
    /// resulting XMTP message has content type
    /// `xmtp.org/multiRemoteStaticAttachment:1.0` and one local DB row whose
    /// `attachmentUrls` holds an ordered JSON array of `StoredRemoteAttachment`
    /// — mirroring the shape `handleMultiRemoteAttachmentContent` produces on
    /// the receive path. The assistant builder uses this so the whole media
    /// bundle lands at the agent in a single delivery.
    func sendMultiRemoteAttachment(items: [MultiAttachmentBundleItem]) async throws -> String

    // MARK: - Replies

    /// Send a video from a local file URL.
    /// Returns a tracking key for dependency management.
    func sendVideo(at fileURL: URL, replyToMessageId: String?) async throws -> String

    /// Send a voice memo from a local audio file URL.
    func sendVoiceMemo(at fileURL: URL, duration: TimeInterval, waveformLevels: [Float]?, replyToMessageId: String?) async throws -> String

    /// Send a generic file attachment from a local file URL.
    func sendFile(at fileURL: URL, filename: String, mimeType: String, replyToMessageId: String?) async throws -> String

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

enum OutgoingMessageWriterError: Error, CustomStringConvertible {
    case conversationNotFound(conversationId: String)
    case eagerUploadNotFound
    case parentMessageNotFound
    case eagerUploadCancelled

    var description: String {
        switch self {
        case .conversationNotFound(let conversationId):
            return "Conversation not found in XMTP local store: \(conversationId)"
        case .eagerUploadNotFound:
            return "Eager upload not found"
        case .parentMessageNotFound:
            return "Parent message not found"
        case .eagerUploadCancelled:
            return "Eager upload was cancelled"
        }
    }
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
        /// Continuations registered via `awaitEagerUpload` — separate from
        /// `waitingContinuation` (which is the single-shot slot consumed by
        /// `processEagerPhoto`), so callers can observe upload completion
        /// without disturbing the send pipeline. Drained on success, error,
        /// or cancellation.
        var completionWaiters: [CheckedContinuation<Void, Error>] = []
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

    private struct EagerVideoUploadState {
        let clientMessageId: String
        let originalURL: URL
        let localCacheURL: URL
        let filename: String
        let thumbnailData: Data
        let width: Int
        let height: Int
        let duration: Double
        var prepared: PreparedBackgroundUpload?
        var compressedFileURL: URL?
        var processingCompleted: Bool = false
        var processingError: Error?
        var waitingContinuation: CheckedContinuation<Void, Error>?
        /// Mirror of `EagerUploadState.completionWaiters` for videos.
        var completionWaiters: [CheckedContinuation<Void, Error>] = []
        var replyContext: ReplyContext?
    }

    private struct QueuedEagerVideo {
        let trackingKey: String
    }

    private enum QueuedMessage {
        case text(QueuedTextMessage)
        case photo(QueuedPhotoMessage)
        case video(QueuedVideoMessage)
        case audio(QueuedAudioMessage)
        case eagerPhoto(QueuedEagerPhoto)
        case eagerVideo(QueuedEagerVideo)
    }

    private let sessionStateManager: any SessionStateManagerProtocol
    private let databaseWriter: any DatabaseWriter
    private let conversationId: String
    private let photoService: any PhotoAttachmentServiceProtocol
    private let pendingUploadWriter: any PendingPhotoUploadWriterProtocol
    private let backgroundUploadManager: any BackgroundUploadManagerProtocol
    private let attachmentLocalStateWriter: any AttachmentLocalStateWriterProtocol
    private let contactSyncCoordinator: (any ContactSyncCoordinatorProtocol)?

    private var messageQueue: [QueuedMessage] = []
    private var isProcessingQueue: Bool = false
    private var eagerUploads: [String: EagerUploadState] = [:]
    private var eagerVideoUploads: [String: EagerVideoUploadState] = [:]
    private var publishedPhotoKeys: Set<String> = []
    private var pendingTexts: [QueuedTextMessage] = []

    nonisolated(unsafe) private let sentMessageSubject: PassthroughSubject<String, Never> = .init()

    nonisolated var sentMessage: AnyPublisher<String, Never> {
        sentMessageSubject.eraseToAnyPublisher()
    }

    init(
        sessionStateManager: any SessionStateManagerProtocol,
        databaseWriter: any DatabaseWriter,
        conversationId: String,
        photoService: any PhotoAttachmentServiceProtocol,
        pendingUploadWriter: any PendingPhotoUploadWriterProtocol,
        backgroundUploadManager: any BackgroundUploadManagerProtocol,
        attachmentLocalStateWriter: any AttachmentLocalStateWriterProtocol,
        contactSyncCoordinator: (any ContactSyncCoordinatorProtocol)? = nil
    ) {
        self.sessionStateManager = sessionStateManager
        self.databaseWriter = databaseWriter
        self.conversationId = conversationId
        self.photoService = photoService
        self.pendingUploadWriter = pendingUploadWriter
        self.backgroundUploadManager = backgroundUploadManager
        self.attachmentLocalStateWriter = attachmentLocalStateWriter
        self.contactSyncCoordinator = contactSyncCoordinator
    }

    /// Fires the contact-sync coordinator on first outbound persist for the
    /// conversation. Fire-and-forget; errors are logged. Safe to call from
    /// every text/photo save site — the coordinator short-circuits when a
    /// sync marker already exists.
    private func enqueueContactSyncIfNeeded() {
        guard let coordinator = contactSyncCoordinator else { return }
        let conversationId = self.conversationId
        Task.detached {
            do {
                try await coordinator.syncContactsOnFirstMessage(for: conversationId)
            } catch {
                Log.error("Contact sync failed for \(conversationId): \(error)")
            }
        }
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

        let inboxReady = try await sessionStateManager.waitForInboxReadyResult()

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
                let waiters = state.completionWaiters
                state.waitingContinuation = nil
                state.completionWaiters = []
                eagerUploads[trackingKey] = state
                Log.debug("handleUploadCompletion: Upload succeeded, has continuation: \(continuation != nil)")
                continuation?.resume()
                for waiter in waiters { waiter.resume() }
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
                let waiters = state.completionWaiters
                state.waitingContinuation = nil
                state.completionWaiters = []
                eagerUploads[trackingKey] = state
                let error: Error = result.error ?? PhotoAttachmentError.uploadFailed("Eager upload failed")
                continuation?.resume(throwing: error)
                for waiter in waiters { waiter.resume(throwing: error) }
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

        let inboxReady = try await sessionStateManager.waitForInboxReadyResult()
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
        if var state = eagerUploads[trackingKey] {
            Log.debug("Cancelling eager upload for: \(trackingKey)")

            await backgroundUploadManager.cancelUpload(taskId: state.prepared.taskId)

            try? await pendingUploadWriter.delete(taskId: state.prepared.taskId)
            try? FileManager.default.removeItem(at: state.prepared.encryptedFileURL)

            // Note: No need to delete from DBMessage - the message was never saved to the database
            // (that only happens in sendEagerPhoto when user taps Send)

            PhotoUploadProgressTracker.shared.clear(key: trackingKey)

            await markPhotoFailed(trackingKey: trackingKey)

            // Resume any awaiter inside `processEagerPhoto`'s continuation before
            // tearing down the entry — otherwise Swift's CheckedContinuation runtime
            // traps on the leak. Mirrors the video path below.
            let waitingContinuation = state.waitingContinuation
            let waiters = state.completionWaiters
            state.waitingContinuation = nil
            state.completionWaiters = []
            eagerUploads.removeValue(forKey: trackingKey)
            waitingContinuation?.resume(throwing: OutgoingMessageWriterError.eagerUploadCancelled)
            for waiter in waiters { waiter.resume(throwing: OutgoingMessageWriterError.eagerUploadCancelled) }
        } else if var state = eagerVideoUploads[trackingKey] {
            Log.debug("Cancelling eager video upload for: \(trackingKey)")

            if let prepared = state.prepared {
                await backgroundUploadManager.cancelUpload(taskId: prepared.taskId)
                try? await pendingUploadWriter.delete(taskId: prepared.taskId)
                try? FileManager.default.removeItem(at: prepared.encryptedFileURL)
            }
            if let compressedFileURL = state.compressedFileURL {
                try? FileManager.default.removeItem(at: compressedFileURL)
            }
            try? FileManager.default.removeItem(at: state.originalURL)

            PhotoUploadProgressTracker.shared.clear(key: trackingKey)

            await markPhotoFailed(trackingKey: trackingKey)

            let waitingContinuation = state.waitingContinuation
            let waiters = state.completionWaiters
            state.waitingContinuation = nil
            state.completionWaiters = []
            eagerVideoUploads.removeValue(forKey: trackingKey)
            waitingContinuation?.resume(throwing: OutgoingMessageWriterError.eagerUploadCancelled)
            for waiter in waiters { waiter.resume(throwing: OutgoingMessageWriterError.eagerUploadCancelled) }
        }
    }

    // MARK: - Awaiting an Eager Upload

    func awaitEagerUpload(trackingKey: String) async throws {
        if var state = eagerUploads[trackingKey] {
            if state.uploadCompleted { return }
            if let error = state.uploadError { throw error }
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                state.completionWaiters.append(continuation)
                eagerUploads[trackingKey] = state
            }
            return
        }
        if var state = eagerVideoUploads[trackingKey] {
            if state.processingCompleted { return }
            if let error = state.processingError { throw error }
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                state.completionWaiters.append(continuation)
                eagerVideoUploads[trackingKey] = state
            }
            return
        }
        // No record for this key — either it already finished and was reaped
        // by `processEagerPhoto` / video pipeline, or it was never started.
        // Either way, treat as "done" so callers don't hang.
    }

    // MARK: - Multi-Remote-Attachment Bundle

    private struct ResolvedBundleEntry {
        let info: MultiRemoteAttachment.RemoteAttachmentInfo
        let stored: StoredRemoteAttachment
        let trackingURL: URL?
        let thumbnail: ImageType?
    }

    func sendMultiRemoteAttachment(items: [MultiAttachmentBundleItem]) async throws -> String {
        guard !items.isEmpty else {
            throw OutgoingMessageWriterError.eagerUploadNotFound
        }
        let inboxReady = try await sessionStateManager.waitForInboxReadyResult()
        let conversationIdLocal = self.conversationId
        let clientMessageId = UUID().uuidString
        let perfStart = CFAbsoluteTimeGetCurrent()

        let entries = try await resolveBundleEntries(items: items, inboxReady: inboxReady)
        let jsonList = try entries.map { entry -> String in
            guard let json = try? entry.stored.toJSON() else {
                throw PhotoAttachmentError.encryptionFailed
            }
            return json
        }
        try await saveMultiAttachmentToDatabase(
            clientMessageId: clientMessageId,
            attachmentUrls: entries.map { $0.trackingURL?.absoluteString ?? UUID().uuidString }
        )
        cacheBundleThumbnails(entries: entries, jsonList: jsonList)

        guard let sender = try await inboxReady.client.messageSender(for: conversationIdLocal) else {
            try? await markMessageFailed(clientMessageId: clientMessageId)
            throw OutgoingMessageWriterError.conversationNotFound(conversationId: conversationIdLocal)
        }
        let multi = MultiRemoteAttachment(remoteAttachments: entries.map { $0.info })
        let messageId: String
        do {
            messageId = try await sender.prepare(multiRemoteAttachment: multi)
        } catch {
            try? await markMessageFailed(clientMessageId: clientMessageId)
            throw error
        }
        try await rewriteBundleMessageRow(clientMessageId: clientMessageId, messageId: messageId, jsonList: jsonList)
        await migrateBundleAttachmentKeys(entries: entries, jsonList: jsonList)

        do {
            try await sender.publish()
        } catch {
            try? await markMessageFailed(messageId: messageId)
            throw error
        }
        try? await markMessagePublished(messageId: messageId)
        await finalizeBundleLocalState(entries: entries, jsonList: jsonList)

        let perfElapsed = String(format: "%.0f", (CFAbsoluteTimeGetCurrent() - perfStart) * 1000)
        Log.info("[PERF] message.publish_multi: \(perfElapsed)ms id=\(messageId) count=\(entries.count)")
        QAEvent.emit(.message, "sent", ["id": messageId, "conversation": conversationIdLocal, "type": "multi_remote_attachment", "count": "\(entries.count)"])
        return messageId
    }

    private func resolveBundleEntries(
        items: [MultiAttachmentBundleItem],
        inboxReady: InboxReadyResult
    ) async throws -> [ResolvedBundleEntry] {
        var entries: [ResolvedBundleEntry] = []
        for item in items {
            switch item {
            case .eagerPhoto(let key):
                entries.append(try await resolveEagerPhotoForBundle(trackingKey: key))
            case .eagerVideo(let key):
                entries.append(try await resolveEagerVideoForBundle(trackingKey: key))
            case let .voiceMemo(url, duration, levels):
                entries.append(try await resolveVoiceMemoForBundle(
                    url: url,
                    duration: duration,
                    waveformLevels: levels,
                    inboxReady: inboxReady
                ))
            case let .file(url, filename, mimeType):
                entries.append(try await resolveFileForBundle(
                    url: url,
                    filename: filename,
                    mimeType: mimeType,
                    inboxReady: inboxReady
                ))
            }
        }
        return entries
    }

    private func cacheBundleThumbnails(entries: [ResolvedBundleEntry], jsonList: [String]) {
        for (idx, entry) in entries.enumerated() {
            if let thumbnail = entry.thumbnail {
                ImageCacheContainer.shared.cacheImage(thumbnail, for: jsonList[idx], storageTier: .persistent)
            }
        }
    }

    private func rewriteBundleMessageRow(clientMessageId: String, messageId: String, jsonList: [String]) async throws {
        let attachmentUrlsJSONString: String
        do {
            let data = try JSONEncoder().encode(jsonList)
            attachmentUrlsJSONString = String(data: data, encoding: .utf8) ?? "[]"
        } catch {
            attachmentUrlsJSONString = "[]"
        }
        try await databaseWriter.write { db in
            try db.execute(
                sql: "UPDATE message SET id = ?, attachmentUrls = ? WHERE id = ?",
                arguments: [messageId, attachmentUrlsJSONString, clientMessageId]
            )
            try db.execute(
                sql: "UPDATE message SET sourceMessageId = ? WHERE sourceMessageId = ?",
                arguments: [messageId, clientMessageId]
            )
        }
    }

    private func migrateBundleAttachmentKeys(entries: [ResolvedBundleEntry], jsonList: [String]) async {
        for (idx, entry) in entries.enumerated() {
            if let trackingURL = entry.trackingURL {
                try? await attachmentLocalStateWriter.migrateKey(from: trackingURL.absoluteString, to: jsonList[idx])
            }
        }
    }

    private func finalizeBundleLocalState(entries: [ResolvedBundleEntry], jsonList: [String]) async {
        for (idx, entry) in entries.enumerated() {
            if let trackingURL = entry.trackingURL,
               trackingURL.isFileURL,
               FileManager.default.fileExists(atPath: trackingURL.path) {
                await OutgoingMediaLocalCache.shared.register(trackingURL, for: jsonList[idx])
            }
            sentMessageSubject.send(jsonList[idx])
        }
    }

    private func resolveEagerPhotoForBundle(trackingKey: String) async throws -> ResolvedBundleEntry {
        try await awaitEagerUpload(trackingKey: trackingKey)
        guard let state = eagerUploads[trackingKey] else {
            throw OutgoingMessageWriterError.eagerUploadNotFound
        }
        if let error = state.uploadError { throw error }
        let prepared = state.prepared
        let info = MultiRemoteAttachment.RemoteAttachmentInfo(
            url: prepared.assetURL,
            filename: prepared.filename,
            contentLength: 0,
            contentDigest: prepared.contentDigest,
            nonce: prepared.encryptionNonce,
            scheme: "https",
            salt: prepared.encryptionSalt,
            secret: prepared.encryptionSecret
        )
        let stored = StoredRemoteAttachment(
            url: prepared.assetURL,
            contentDigest: prepared.contentDigest,
            secret: prepared.encryptionSecret,
            salt: prepared.encryptionSalt,
            nonce: prepared.encryptionNonce,
            filename: prepared.filename
        )
        try? await pendingUploadWriter.delete(taskId: prepared.taskId)
        try? FileManager.default.removeItem(at: prepared.encryptedFileURL)
        eagerUploads.removeValue(forKey: trackingKey)
        return ResolvedBundleEntry(
            info: info,
            stored: stored,
            trackingURL: URL(string: trackingKey),
            thumbnail: state.image
        )
    }

    private func resolveEagerVideoForBundle(trackingKey: String) async throws -> ResolvedBundleEntry {
        try await awaitEagerUpload(trackingKey: trackingKey)
        guard let state = eagerVideoUploads[trackingKey], let prepared = state.prepared else {
            throw OutgoingMessageWriterError.eagerUploadNotFound
        }
        if let error = state.processingError { throw error }
        let info = MultiRemoteAttachment.RemoteAttachmentInfo(
            url: prepared.assetURL,
            filename: state.filename,
            contentLength: 0,
            contentDigest: prepared.contentDigest,
            nonce: prepared.encryptionNonce,
            scheme: "https",
            salt: prepared.encryptionSalt,
            secret: prepared.encryptionSecret
        )
        let stored = StoredRemoteAttachment(
            url: prepared.assetURL,
            contentDigest: prepared.contentDigest,
            secret: prepared.encryptionSecret,
            salt: prepared.encryptionSalt,
            nonce: prepared.encryptionNonce,
            filename: state.filename,
            mimeType: "video/mp4",
            mediaWidth: state.width,
            mediaHeight: state.height,
            mediaDuration: state.duration,
            thumbnailDataBase64: state.thumbnailData.base64EncodedString()
        )
        try? await pendingUploadWriter.delete(taskId: prepared.taskId)
        try? FileManager.default.removeItem(at: prepared.encryptedFileURL)
        if let compressedFileURL = state.compressedFileURL {
            try? FileManager.default.removeItem(at: compressedFileURL)
        }
        eagerVideoUploads.removeValue(forKey: trackingKey)
        let thumbnail = ImageType(data: state.thumbnailData)
        return ResolvedBundleEntry(
            info: info,
            stored: stored,
            trackingURL: URL(string: trackingKey),
            thumbnail: thumbnail
        )
    }

    private func resolveVoiceMemoForBundle(
        url: URL,
        duration: TimeInterval,
        waveformLevels: [Float],
        inboxReady: InboxReadyResult
    ) async throws -> ResolvedBundleEntry {
        let filename = "voice_memo_\(Int(Date().timeIntervalSince1970))_\(UUID().uuidString.prefix(8)).m4a"
        let mimeType = "audio/m4a"
        let entry = try await encryptAndUploadForBundle(
            sourceURL: url,
            filename: filename,
            mimeType: mimeType,
            inboxReady: inboxReady
        )
        try? await attachmentLocalStateWriter.saveWaveformLevels(waveformLevels, for: url.absoluteString)
        try? await attachmentLocalStateWriter.saveDuration(duration, for: url.absoluteString)
        let stored = StoredRemoteAttachment(
            url: entry.stored.url,
            contentDigest: entry.stored.contentDigest,
            secret: entry.stored.secret,
            salt: entry.stored.salt,
            nonce: entry.stored.nonce,
            filename: entry.stored.filename,
            mimeType: entry.stored.mimeType,
            mediaWidth: entry.stored.mediaWidth,
            mediaHeight: entry.stored.mediaHeight,
            mediaDuration: duration,
            thumbnailDataBase64: entry.stored.thumbnailDataBase64
        )
        return ResolvedBundleEntry(
            info: entry.info,
            stored: stored,
            trackingURL: url,
            thumbnail: nil
        )
    }

    private func resolveFileForBundle(
        url: URL,
        filename: String,
        mimeType: String,
        inboxReady: InboxReadyResult
    ) async throws -> ResolvedBundleEntry {
        return try await encryptAndUploadForBundle(
            sourceURL: url,
            filename: filename,
            mimeType: mimeType,
            inboxReady: inboxReady
        )
    }

    private func encryptAndUploadForBundle(
        sourceURL: URL,
        filename: String,
        mimeType: String,
        inboxReady: InboxReadyResult
    ) async throws -> ResolvedBundleEntry {
        let fileData = try Data(contentsOf: sourceURL)
        let attachment = Attachment(
            filename: filename,
            mimeType: mimeType,
            data: fileData
        )
        let encrypted = try RemoteAttachment.encodeEncrypted(
            content: attachment,
            codec: AttachmentCodec()
        )

        let presigned = try await inboxReady.apiClient.getPresignedUploadURL(
            filename: filename,
            contentType: "application/octet-stream"
        )
        guard let uploadURL = URL(string: presigned.uploadURL) else {
            throw PhotoAttachmentError.invalidURL
        }

        let taskId = UUID().uuidString
        let encryptedFileURL = try saveToTemp(data: encrypted.payload, taskId: taskId)
        defer { try? FileManager.default.removeItem(at: encryptedFileURL) }

        try await backgroundUploadManager.startUpload(
            fileURL: encryptedFileURL,
            uploadURL: uploadURL,
            contentType: "application/octet-stream",
            taskId: taskId
        )
        let result = await backgroundUploadManager.waitForCompletion(taskId: taskId)
        guard result.success else {
            throw result.error ?? PhotoAttachmentError.uploadFailed("bundle attachment upload failed")
        }

        // Best-effort: record dimensions/mime so the local-state writer can
        // surface them to the renderer if anyone ever looks. Voice memo's
        // waveform/duration are written separately by the caller.
        try? await attachmentLocalStateWriter.saveWithDimensions(
            attachmentKey: sourceURL.absoluteString,
            conversationId: conversationId,
            width: 0,
            height: 0,
            mimeType: mimeType
        )

        let info = MultiRemoteAttachment.RemoteAttachmentInfo(
            url: presigned.assetURL,
            filename: filename,
            contentLength: UInt32(clamping: fileData.count),
            contentDigest: encrypted.digest,
            nonce: encrypted.nonce,
            scheme: "https",
            salt: encrypted.salt,
            secret: encrypted.secret
        )
        let stored = StoredRemoteAttachment(
            url: presigned.assetURL,
            contentDigest: encrypted.digest,
            secret: encrypted.secret,
            salt: encrypted.salt,
            nonce: encrypted.nonce,
            filename: filename,
            mimeType: mimeType
        )
        return ResolvedBundleEntry(
            info: info,
            stored: stored,
            trackingURL: sourceURL,
            thumbnail: nil
        )
    }

    private func saveMultiAttachmentToDatabase(
        clientMessageId: String,
        attachmentUrls: [String]
    ) async throws {
        let senderId: String
        if case .ready(let result) = sessionStateManager.currentState {
            senderId = result.client.inboxId
        } else if case .backgrounded(let result) = sessionStateManager.currentState {
            senderId = result.client.inboxId
        } else {
            let inboxReady = try await sessionStateManager.waitForInboxReadyResult()
            senderId = inboxReady.client.inboxId
        }

        let date = Date()
        let conversationIdLocal = self.conversationId

        try await databaseWriter.write { db in
            let maxSortId = try Int64.fetchOne(db, sql: """
                SELECT COALESCE(MAX(sortId), 0) FROM message WHERE conversationId = ?
            """, arguments: [conversationIdLocal]) ?? 0
            let sortId = maxSortId + 1
            let localMessage = DBMessage(
                id: clientMessageId,
                clientMessageId: clientMessageId,
                conversationId: conversationIdLocal,
                senderId: senderId,
                dateNs: date.nanosecondsSince1970,
                date: date,
                sortId: sortId,
                status: .unpublished,
                messageType: .original,
                contentType: .attachments,
                text: nil,
                emoji: nil,
                invite: nil,
                linkPreview: nil,
                sourceMessageId: nil,
                attachmentUrls: attachmentUrls,
                update: nil
            )
            try localMessage.save(db)
        }
    }

    // MARK: - Eager Video Upload

    func startEagerVideoUpload(at fileURL: URL) async throws -> String {
        let clientMessageId = UUID().uuidString
        let filename = "video_\(Int(Date().timeIntervalSince1970))_\(UUID().uuidString.prefix(8)).mp4"
        let localCacheURL = try photoService.localCacheURL(for: filename)
        let trackingKey = localCacheURL.absoluteString

        Log.debug("Starting eager video upload for: \(trackingKey)")

        // Probe dimensions and generate thumbnail synchronously so the bubble
        // has content to render the moment the user taps Send. Compression and
        // upload run in the background.
        let asset = AVURLAsset(url: fileURL)
        guard let videoTrack = try await asset.loadTracks(withMediaType: .video).first else {
            throw VideoCompressionError.invalidAsset
        }
        let naturalSize = try await videoTrack.load(.naturalSize)
        let transform = try await videoTrack.load(.preferredTransform)
        let transformedSize = naturalSize.applying(transform)
        let width: Int = Int(abs(transformedSize.width))
        let height: Int = Int(abs(transformedSize.height))
        let durationCMTime = try await asset.load(.duration)
        let duration: Double = CMTimeGetSeconds(durationCMTime)

        let compressionService = VideoCompressionService()
        let thumbnailData = try await compressionService.generateThumbnail(for: asset)

        if let thumbnailImage = ImageType(data: thumbnailData) {
            ImageCacheContainer.shared.cacheImage(thumbnailImage, for: trackingKey, storageTier: .persistent)
        }

        PhotoUploadProgressTracker.shared.setStage(.preparing, for: trackingKey)

        let state = EagerVideoUploadState(
            clientMessageId: clientMessageId,
            originalURL: fileURL,
            localCacheURL: localCacheURL,
            filename: filename,
            thumbnailData: thumbnailData,
            width: width,
            height: height,
            duration: duration
        )
        eagerVideoUploads[trackingKey] = state

        Task { [weak self] in
            guard let self else { return }
            await self.runEagerVideoPipeline(trackingKey: trackingKey)
        }

        return trackingKey
    }

    private func runEagerVideoPipeline(trackingKey: String) async {
        let tracker = PhotoUploadProgressTracker.shared
        do {
            guard let state = eagerVideoUploads[trackingKey] else { return }

            let compressionService = VideoCompressionService()
            let compressed = try await compressionService.compressVideo(at: state.originalURL)

            // Mirror the compressed file into the local cache so the renderer can
            // resolve the message's attachment URL once Send happens.
            try FileManager.default.createDirectory(
                at: state.localCacheURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try? FileManager.default.removeItem(at: state.localCacheURL)
            try FileManager.default.copyItem(at: compressed.fileURL, to: state.localCacheURL)

            try await attachmentLocalStateWriter.saveWithDimensions(
                attachmentKey: trackingKey,
                conversationId: conversationId,
                width: state.width,
                height: state.height,
                mimeType: "video/mp4"
            )
            try? await attachmentLocalStateWriter.saveDuration(state.duration, for: trackingKey)

            let inboxReady = try await sessionStateManager.waitForInboxReadyResult()
            let fileData = try Data(contentsOf: compressed.fileURL)
            let attachment = Attachment(
                filename: state.filename,
                mimeType: "video/mp4",
                data: fileData
            )
            let encrypted = try RemoteAttachment.encodeEncrypted(
                content: attachment,
                codec: AttachmentCodec()
            )
            let presignedURLs = try await inboxReady.apiClient.getPresignedUploadURL(
                filename: state.filename,
                contentType: "application/octet-stream"
            )
            guard let uploadURL = URL(string: presignedURLs.uploadURL) else {
                throw PhotoAttachmentError.invalidURL
            }

            let taskId = UUID().uuidString
            let encryptedFileURL = try saveToTemp(data: encrypted.payload, taskId: taskId)

            let prepared = PreparedBackgroundUpload(
                taskId: taskId,
                encryptedFileURL: encryptedFileURL,
                presignedUploadURL: uploadURL,
                assetURL: presignedURLs.assetURL,
                encryptionSecret: encrypted.secret,
                encryptionSalt: encrypted.salt,
                encryptionNonce: encrypted.nonce,
                contentDigest: encrypted.digest,
                filename: state.filename
            )

            // Publish prepared + compressed URL into the shared state BEFORE the
            // upload await so that a cancelEagerUpload mid-upload can find and
            // delete the encrypted file, the compressed file, and the
            // DBPendingPhotoUpload row instead of orphaning them.
            if var s = eagerVideoUploads[trackingKey] {
                s.prepared = prepared
                s.compressedFileURL = compressed.fileURL
                eagerVideoUploads[trackingKey] = s
            }

            let pendingUpload = DBPendingPhotoUpload(
                id: prepared.taskId,
                clientMessageId: state.clientMessageId,
                conversationId: conversationId,
                localCacheURL: trackingKey,
                state: .uploading
            )
            try await pendingUploadWriter.create(pendingUpload)

            tracker.setProgress(stage: .uploading, percentage: 0, for: trackingKey)

            try await backgroundUploadManager.startUpload(
                fileURL: prepared.encryptedFileURL,
                uploadURL: prepared.presignedUploadURL,
                contentType: "application/octet-stream",
                taskId: prepared.taskId
            )

            let result = await backgroundUploadManager.waitForCompletion(taskId: prepared.taskId)

            if result.success {
                try? await pendingUploadWriter.updateState(taskId: prepared.taskId, state: .sending, errorMessage: nil)
                if var s = eagerVideoUploads[trackingKey] {
                    s.processingCompleted = true
                    let cont = s.waitingContinuation
                    let waiters = s.completionWaiters
                    s.waitingContinuation = nil
                    s.completionWaiters = []
                    eagerVideoUploads[trackingKey] = s
                    cont?.resume()
                    for waiter in waiters { waiter.resume() }
                }
            } else {
                tracker.setStage(.failed, for: trackingKey)
                try? await pendingUploadWriter.updateState(
                    taskId: prepared.taskId,
                    state: .failed,
                    errorMessage: result.error?.localizedDescription
                )
                let uploadError: Error = result.error ?? PhotoAttachmentError.uploadFailed("Eager video upload failed")
                await failEagerVideoPipeline(trackingKey: trackingKey, error: uploadError)
            }
        } catch {
            await failEagerVideoPipeline(trackingKey: trackingKey, error: error)
            Log.error("Eager video pipeline failed: \(error)")
        }
    }

    private func failEagerVideoPipeline(trackingKey: String, error: Error) async {
        guard var state = eagerVideoUploads[trackingKey] else {
            await markPhotoFailed(trackingKey: trackingKey)
            return
        }
        state.processingError = error
        let cont = state.waitingContinuation
        let waiters = state.completionWaiters
        state.waitingContinuation = nil
        state.completionWaiters = []
        eagerVideoUploads[trackingKey] = state
        cont?.resume(throwing: error)
        for waiter in waiters { waiter.resume(throwing: error) }
        try? await markMessageFailed(clientMessageId: state.clientMessageId)
        await markPhotoFailed(trackingKey: trackingKey)

        // Reclaim disk + drop the dict entry so failures don't pile up. If
        // processEagerVideo is going to consume the continuation it has
        // already received the error and won't read these.
        if let prepared = state.prepared {
            try? FileManager.default.removeItem(at: prepared.encryptedFileURL)
        }
        if let compressedFileURL = state.compressedFileURL {
            try? FileManager.default.removeItem(at: compressedFileURL)
        }
        try? FileManager.default.removeItem(at: state.originalURL)
        eagerVideoUploads.removeValue(forKey: trackingKey)
    }

    func sendEagerVideo(trackingKey: String) async throws {
        guard let state = eagerVideoUploads[trackingKey] else {
            throw OutgoingMessageWriterError.eagerUploadNotFound
        }

        // saveWithDimensions is idempotent — call it here too in case Send
        // happened before the pipeline got far enough to write it.
        try await attachmentLocalStateWriter.saveWithDimensions(
            attachmentKey: trackingKey,
            conversationId: conversationId,
            width: state.width,
            height: state.height,
            mimeType: "video/mp4"
        )
        try? await attachmentLocalStateWriter.saveDuration(state.duration, for: trackingKey)

        try await savePhotoToDatabase(
            clientMessageId: state.clientMessageId,
            localCacheURL: state.localCacheURL,
            replyContext: state.replyContext
        )

        messageQueue.append(.eagerVideo(QueuedEagerVideo(trackingKey: trackingKey)))
        startProcessingIfNeeded()
    }

    func sendEagerVideoReply(trackingKey: String, toMessageWithClientId parentClientMessageId: String) async throws {
        let replyContext = try await resolveReplyContext(parentClientMessageId: parentClientMessageId)
        guard var state = eagerVideoUploads[trackingKey] else {
            throw OutgoingMessageWriterError.eagerUploadNotFound
        }
        state.replyContext = replyContext
        eagerVideoUploads[trackingKey] = state
        try await sendEagerVideo(trackingKey: trackingKey)
    }

    private func processEagerVideo(trackingKey: String) async throws {
        guard var state = eagerVideoUploads[trackingKey] else {
            throw OutgoingMessageWriterError.eagerUploadNotFound
        }

        if !state.processingCompleted && state.processingError == nil {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                state.waitingContinuation = continuation
                eagerVideoUploads[trackingKey] = state
            }
            guard let updated = eagerVideoUploads[trackingKey] else {
                throw OutgoingMessageWriterError.eagerUploadNotFound
            }
            state = updated
        }

        if let error = state.processingError {
            throw error
        }

        guard let prepared = state.prepared else {
            throw OutgoingMessageWriterError.eagerUploadNotFound
        }

        PhotoUploadProgressTracker.shared.setStage(.publishing, for: trackingKey)

        let inboxReady = try await sessionStateManager.waitForInboxReadyResult()

        let storedAttachment = StoredRemoteAttachment(
            url: prepared.assetURL,
            contentDigest: prepared.contentDigest,
            secret: prepared.encryptionSecret,
            salt: prepared.encryptionSalt,
            nonce: prepared.encryptionNonce,
            filename: state.filename,
            mimeType: "video/mp4",
            mediaWidth: state.width,
            mediaHeight: state.height,
            mediaDuration: state.duration,
            thumbnailDataBase64: state.thumbnailData.base64EncodedString()
        )

        let thumbnailImage: ImageType? = ImageType(data: state.thumbnailData)

        _ = try await publishAttachment(
            storedAttachment: storedAttachment,
            clientMessageId: state.clientMessageId,
            trackingKey: trackingKey,
            thumbnailImage: thumbnailImage,
            inboxReady: inboxReady,
            replyContext: state.replyContext,
            mediaType: "video"
        )

        try? FileManager.default.removeItem(at: prepared.encryptedFileURL)
        if let compressedFileURL = state.compressedFileURL {
            try? FileManager.default.removeItem(at: compressedFileURL)
        }
        try? FileManager.default.removeItem(at: state.originalURL)
        eagerVideoUploads.removeValue(forKey: trackingKey)
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
        /// Filename used for the local cache copy / tracking key. Defaults to `filename`.
        /// Override when `filename` may collide across sends (e.g. user-picked files).
        var cacheFilename: String?
    }

    private func sendFileAttachment(
        params: AttachmentUploadParams,
        replyToMessageId: String?
    ) async throws -> String {
        let clientMessageId = UUID().uuidString
        let localCacheURL = try photoService.localCacheURL(for: params.cacheFilename ?? params.filename)

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
            let inboxReady = try await sessionStateManager.waitForInboxReadyResult()

            let fileData = try Data(contentsOf: params.dataURL)
            let attachment = Attachment(
                filename: params.filename,
                mimeType: params.mimeType,
                data: fileData
            )

            let encrypted = try RemoteAttachment.encodeEncrypted(
                content: attachment,
                codec: AttachmentCodec()
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

        let remoteAttachment = try RemoteAttachment(
            url: storedAttachment.url,
            contentDigest: storedAttachment.contentDigest,
            secret: storedAttachment.secret,
            salt: storedAttachment.salt,
            nonce: storedAttachment.nonce,
            scheme: .https,
            contentLength: nil,
            filename: storedAttachment.filename
        )

        guard let sender = try await inboxReady.client.messageSender(for: conversationId) else {
            tracker.setStage(.failed, for: trackingKey)
            try? await markMessageFailed(clientMessageId: clientMessageId)
            throw OutgoingMessageWriterError.conversationNotFound(conversationId: conversationId)
        }

        do {
            let messageId: String
            if let replyContext {
                let reply = Reply(reference: replyContext.parentDbId, content: remoteAttachment, contentType: ContentTypeRemoteAttachment)
                messageId = try await sender.prepare(reply: reply)
            } else {
                messageId = try await sender.prepare(remoteAttachment: remoteAttachment)
            }

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

            try await sender.publish()

            ImageCacheContainer.shared.removeImage(for: trackingKey)

            try? await markMessagePublished(messageId: messageId)
            tracker.setStage(.completed, for: trackingKey)
            sentMessageSubject.send(json)
            markPhotoPublished(trackingKey: trackingKey)

            // For media we still have on disk locally (trackingKey is the
            // file:// URL of the local cached copy), publish the mapping so
            // the renderer can play from disk without re-downloading.
            if let trackingURL = URL(string: trackingKey),
               trackingURL.isFileURL,
               FileManager.default.fileExists(atPath: trackingURL.path) {
                await OutgoingMediaLocalCache.shared.register(trackingURL, for: json)
            }

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

    // MARK: - File

    func sendFile(at fileURL: URL, filename: String, mimeType: String, replyToMessageId: String? = nil) async throws -> String {
        // The hydrator in MessagesRepository strips everything before the first underscore
        // when deriving a display filename from a local file:// key, so the prefix here
        // must contain no underscores — only a single one separating prefix from filename.
        let uniquePrefix = "\(Int(Date().timeIntervalSince1970))-\(UUID().uuidString.prefix(8))"
        let params = AttachmentUploadParams(
            dataURL: fileURL,
            filename: filename,
            mimeType: mimeType,
            mediaTypeLabel: "file",
            cacheFilename: "\(uniquePrefix)_\(filename)"
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
                case .eagerVideo(let queued):
                    try await processEagerVideo(trackingKey: queued.trackingKey)
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
                case .eagerVideo(let queued):
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
        if case .ready(let result) = sessionStateManager.currentState {
            senderId = result.client.inboxId
        } else if case .backgrounded(let result) = sessionStateManager.currentState {
            senderId = result.client.inboxId
        } else {
            let inboxReady = try await sessionStateManager.waitForInboxReadyResult()
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
        enqueueContactSyncIfNeeded()
    }

    private func savePhotoToDatabase(clientMessageId: String, localCacheURL: URL, replyContext: ReplyContext? = nil) async throws {
        let senderId: String
        if case .ready(let result) = sessionStateManager.currentState {
            senderId = result.client.inboxId
        } else if case .backgrounded(let result) = sessionStateManager.currentState {
            senderId = result.client.inboxId
        } else {
            let inboxReady = try await sessionStateManager.waitForInboxReadyResult()
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
        enqueueContactSyncIfNeeded()
    }

    // MARK: - Network Publishing (Sequential)

    private func publishText(_ queued: QueuedTextMessage) async throws {
        let perfStart = CFAbsoluteTimeGetCurrent()
        let inboxReady = try await sessionStateManager.waitForInboxReadyResult()
        let client = inboxReady.client

        guard let sender = try await client.messageSender(for: conversationId) else {
            try? await markMessageFailed(clientMessageId: queued.clientMessageId)
            throw OutgoingMessageWriterError.conversationNotFound(conversationId: conversationId)
        }

        let xmtpMessageId: String
        if let replyContext = queued.replyContext {
            let reply = Reply(reference: replyContext.parentDbId, content: queued.text, contentType: ContentTypeText)
            xmtpMessageId = try await sender.prepare(reply: reply)
        } else {
            xmtpMessageId = try await sender.prepare(text: queued.text)
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
            try await sender.publish()
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

        let inboxReady = try await sessionStateManager.waitForInboxReadyResult()

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

        let inboxReady = try await sessionStateManager.waitForInboxReadyResult()

        let videoData = try Data(contentsOf: queued.localCacheURL)
        let attachment = Attachment(
            filename: queued.filename,
            mimeType: "video/mp4",
            data: videoData
        )

        let encrypted = try RemoteAttachment.encodeEncrypted(
            content: attachment,
            codec: AttachmentCodec()
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

        let inboxReady = try await sessionStateManager.waitForInboxReadyResult()

        let audioData = try Data(contentsOf: queued.localCacheURL)
        let attachment = Attachment(
            filename: queued.filename,
            mimeType: queued.mimeType,
            data: audioData
        )

        let encrypted = try RemoteAttachment.encodeEncrypted(
            content: attachment,
            codec: AttachmentCodec()
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
        let inboxReady = try await sessionStateManager.waitForInboxReadyResult()
        let client = inboxReady.client

        guard let sender = try await client.messageSender(for: conversationId) else {
            try? await markMessageFailed(messageId: messageId)
            throw OutgoingMessageWriterError.conversationNotFound(conversationId: conversationId)
        }

        do {
            try await sender.publishMessage(messageId: messageId)
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
