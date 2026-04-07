import ConvosLogging
import Foundation
import Speech

/// Coordinates local voice memo transcription jobs: deduplicates work, loads the
/// encrypted attachment, persists pending/completed/failed state via the writer, and
/// skips messages that already have a transcript.
public protocol VoiceMemoTranscriptionServicing: Sendable {
    /// Enqueues a transcription job for the given voice memo if one has not already run.
    ///
    /// - Parameters:
    ///   - messageId: Stable message id that owns the voice memo attachment.
    ///   - conversationId: Conversation the message belongs to.
    ///   - attachmentKey: The stored-remote-attachment JSON string used by
    ///     `RemoteAttachmentLoader` to fetch and decrypt the audio.
    ///   - mimeType: MIME type of the audio payload, used to derive a file extension.
    func enqueueIfNeeded(
        messageId: String,
        conversationId: String,
        attachmentKey: String,
        mimeType: String
    ) async

    /// Re-runs transcription for a voice memo that previously failed (or completed).
    /// Bypasses the "already has a transcript" guard. Intended to be called from an
    /// explicit user retry action.
    func retry(
        messageId: String,
        conversationId: String,
        attachmentKey: String,
        mimeType: String
    ) async

    /// Whether the user has already granted on-device speech recognition permission.
    /// Used by the auto-enqueue scheduler to decide whether transcription should
    /// happen automatically (post-authorization) or whether the UI should instead
    /// show a "Tap to transcribe" affordance for the very first voice memo.
    func hasSpeechPermission() -> Bool
}

public final class VoiceMemoTranscriptionService: VoiceMemoTranscriptionServicing, @unchecked Sendable {
    /// Filename prefix used by `writeTemporaryAudioFile(data:mimeType:)` so the
    /// init-time cleanup pass can identify orphaned voice memo temp files.
    private static let temporaryFilenamePrefix: String = "convos-voice-memo-"

    private let transcriber: any VoiceMemoTranscribing
    private let attachmentLoader: any RemoteAttachmentLoaderProtocol
    private let transcriptRepository: any VoiceMemoTranscriptRepositoryProtocol
    private let transcriptWriter: any VoiceMemoTranscriptWriterProtocol

    private let state: State = State()

    public init(
        transcriber: any VoiceMemoTranscribing = VoiceMemoTranscriber(),
        attachmentLoader: any RemoteAttachmentLoaderProtocol = RemoteAttachmentLoader(),
        transcriptRepository: any VoiceMemoTranscriptRepositoryProtocol,
        transcriptWriter: any VoiceMemoTranscriptWriterProtocol
    ) {
        self.transcriber = transcriber
        self.attachmentLoader = attachmentLoader
        self.transcriptRepository = transcriptRepository
        self.transcriptWriter = transcriptWriter
        // Sweep any voice memo temp files left over from a previous run — if the
        // app crashed or was force-quit during transcription, the per-job defer
        // block in `runTranscriptionJob` never had a chance to delete them.
        Task.detached(priority: .background) {
            Self.purgeOrphanedTemporaryFiles()
        }
    }

    public func enqueueIfNeeded(
        messageId: String,
        conversationId: String,
        attachmentKey: String,
        mimeType: String
    ) async {
        await enqueue(
            messageId: messageId,
            conversationId: conversationId,
            attachmentKey: attachmentKey,
            mimeType: mimeType,
            forceRetry: false
        )
    }

    public func retry(
        messageId: String,
        conversationId: String,
        attachmentKey: String,
        mimeType: String
    ) async {
        await enqueue(
            messageId: messageId,
            conversationId: conversationId,
            attachmentKey: attachmentKey,
            mimeType: mimeType,
            forceRetry: true
        )
    }

    public func hasSpeechPermission() -> Bool {
        SFSpeechRecognizer.authorizationStatus() == .authorized
    }

    private func enqueue(
        messageId: String,
        conversationId: String,
        attachmentKey: String,
        mimeType: String,
        forceRetry: Bool
    ) async {
        let shouldStart = await state.reserveSlotIfFree(for: messageId)
        guard shouldStart else { return }

        if !forceRetry {
            do {
                if let existing = try await transcriptRepository.transcript(for: messageId) {
                    switch existing.status {
                    case .completed, .pending, .failed, .permanentlyFailed:
                        // Skip when we already have a transcript, a previous attempt
                        // failed (retries should be explicit user action), or a
                        // previous attempt failed permanently (retries cannot help).
                        await state.clear(messageId: messageId)
                        return
                    case .notRequested:
                        // .notRequested is a display-only state and should never
                        // be persisted; if we ever see it in the DB, treat it as
                        // "no record" and proceed.
                        break
                    }
                }
            } catch {
                Log.error("[VoiceMemoTranscription] Failed to read existing transcript for \(messageId): \(error)")
                await state.clear(messageId: messageId)
                return
            }
        }

        let task = Task.detached { [weak self] in
            guard let self else { return }
            await self.runTranscriptionJob(
                messageId: messageId,
                conversationId: conversationId,
                attachmentKey: attachmentKey,
                mimeType: mimeType
            )
        }
        await state.storeTask(task, for: messageId)
    }

    // MARK: - Private

    private func runTranscriptionJob(
        messageId: String,
        conversationId: String,
        attachmentKey: String,
        mimeType: String
    ) async {
        do {
            try await transcriptWriter.markPending(
                messageId: messageId,
                conversationId: conversationId,
                attachmentKey: attachmentKey
            )
        } catch {
            Log.error("[VoiceMemoTranscription] Failed to mark transcript pending for \(messageId): \(error)")
        }

        let fileURL: URL
        do {
            let loaded = try await attachmentLoader.loadAttachmentData(from: attachmentKey)
            fileURL = try Self.writeTemporaryAudioFile(data: loaded.data, mimeType: loaded.mimeType)
        } catch {
            Log.error("[VoiceMemoTranscription] Failed to load audio for \(messageId): \(error)")
            await persistFailure(
                messageId: messageId,
                conversationId: conversationId,
                attachmentKey: attachmentKey,
                error: error
            )
            await state.clear(messageId: messageId)
            return
        }

        defer {
            try? FileManager.default.removeItem(at: fileURL)
        }

        do {
            let text = try await transcriber.transcribe(messageId: messageId, fileURL: fileURL)
            try await transcriptWriter.saveCompleted(
                messageId: messageId,
                conversationId: conversationId,
                attachmentKey: attachmentKey,
                text: text
            )
            Log.info("[VoiceMemoTranscription] Saved transcript for message \(messageId) (\(text.count) chars)")
        } catch is CancellationError {
            // Cancellation propagates from the outer task to the `await` here,
            // but the transcriber's inner unstructured task is not
            // automatically cancelled. Tell the transcriber explicitly so it
            // stops the SpeechAnalyzer pipeline instead of leaving it running
            // in the background until it finishes the audio file naturally.
            await transcriber.cancel(messageId: messageId)
            Log.info("[VoiceMemoTranscription] Transcription cancelled for \(messageId)")
        } catch {
            Log.error("[VoiceMemoTranscription] Transcription failed for \(messageId): \(error)")
            await persistFailure(
                messageId: messageId,
                conversationId: conversationId,
                attachmentKey: attachmentKey,
                error: error
            )
        }

        await state.clear(messageId: messageId)
    }

    /// Records the failure in a way that's appropriate for the user. Permanent
    /// failures (e.g. on-device speech models are not available) cannot be
    /// recovered from by retrying, so we mark the row as `.permanentlyFailed`
    /// — this keeps an entry in the database (so the scheduler's "already has
    /// a row" check short-circuits and no retry loop occurs) while still
    /// telling the UI synthesis path to hide the row entirely. Recoverable
    /// failures still produce a `failed` row so the user can manually retry.
    private func persistFailure(
        messageId: String,
        conversationId: String,
        attachmentKey: String,
        error: Error
    ) async {
        if let transcribeError = error as? VoiceMemoTranscriberError, transcribeError.isPermanentFailure {
            do {
                try await transcriptWriter.markPermanentlyFailed(
                    messageId: messageId,
                    conversationId: conversationId,
                    attachmentKey: attachmentKey,
                    errorDescription: error.localizedDescription
                )
            } catch {
                Log.error("[VoiceMemoTranscription] Failed to mark permanently failed for \(messageId): \(error)")
            }
            return
        }
        do {
            try await transcriptWriter.saveFailed(
                messageId: messageId,
                conversationId: conversationId,
                attachmentKey: attachmentKey,
                errorDescription: error.localizedDescription
            )
        } catch {
            Log.error("[VoiceMemoTranscription] Failed to persist transcript failure for \(messageId): \(error)")
        }
    }

    private static func writeTemporaryAudioFile(data: Data, mimeType: String) throws -> URL {
        let ext = fileExtension(forMimeType: mimeType)
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(temporaryFilenamePrefix)\(UUID().uuidString)")
            .appendingPathExtension(ext)
        try data.write(to: url, options: .atomic)
        return url
    }

    /// Best-effort sweep of stale `convos-voice-memo-*` files in the temporary
    /// directory. Runs on a background task at service init so a crash or force
    /// quit during transcription doesn't leak files until iOS reclaims them.
    /// Files less than 60 seconds old are spared in case another concurrent
    /// transcription is mid-flight.
    private static func purgeOrphanedTemporaryFiles() {
        let fileManager = FileManager.default
        let tempDirectory = fileManager.temporaryDirectory
        let now = Date()
        do {
            let contents = try fileManager.contentsOfDirectory(
                at: tempDirectory,
                includingPropertiesForKeys: [.contentModificationDateKey],
                options: [.skipsHiddenFiles]
            )
            var purged = 0
            for url in contents {
                guard url.lastPathComponent.hasPrefix(temporaryFilenamePrefix) else { continue }
                let modified = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?
                    .contentModificationDate ?? .distantPast
                guard now.timeIntervalSince(modified) > 60 else { continue }
                do {
                    try fileManager.removeItem(at: url)
                    purged += 1
                } catch {
                    Log.error("[VoiceMemoTranscription] Failed to purge stale temp file \(url.lastPathComponent): \(error)")
                }
            }
            if purged > 0 {
                Log.info("[VoiceMemoTranscription] Purged \(purged) stale voice memo temp file(s)")
            }
        } catch {
            // No access to the temp directory or it doesn't exist yet — nothing
            // to clean up.
            Log.info("[VoiceMemoTranscription] Skipping stale temp file purge: \(error.localizedDescription)")
        }
    }

    private static func fileExtension(forMimeType mimeType: String) -> String {
        switch mimeType.lowercased() {
        case "audio/m4a", "audio/mp4", "audio/aac", "audio/x-m4a":
            return "m4a"
        case "audio/mpeg", "audio/mp3":
            return "mp3"
        case "audio/wav", "audio/x-wav":
            return "wav"
        case "audio/caf":
            return "caf"
        default:
            return "m4a"
        }
    }
}

// MARK: - Concurrency state

extension VoiceMemoTranscriptionService {
    fileprivate actor State {
        private enum Slot {
            case reserved
            case running(Task<Void, Never>)
        }

        private var slots: [String: Slot] = [:]

        /// Returns `true` if the caller has successfully reserved the slot and should
        /// proceed. Returns `false` if another enqueue is already in progress for this
        /// message id.
        func reserveSlotIfFree(for messageId: String) -> Bool {
            if slots[messageId] != nil { return false }
            slots[messageId] = .reserved
            return true
        }

        /// Promote a previously-reserved slot to a running slot holding the given
        /// task. If the slot is no longer in the `.reserved` state — because the
        /// detached task already finished and called `clear(messageId:)` while the
        /// caller was suspending on this actor hop — do nothing, so we don't
        /// resurrect a stale entry that would lock the message id out of future
        /// transcription attempts.
        func storeTask(_ task: Task<Void, Never>, for messageId: String) {
            guard case .reserved = slots[messageId] else { return }
            slots[messageId] = .running(task)
        }

        func clear(messageId: String) {
            if case .running(let task) = slots[messageId] {
                task.cancel()
            }
            slots[messageId] = nil
        }
    }
}
