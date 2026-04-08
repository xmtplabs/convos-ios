@testable import ConvosCore
import Combine
import Foundation
import Testing

@Suite("VoiceMemoTranscriptionService", .serialized)
struct VoiceMemoTranscriptionServiceTests {
    @Test("happy path: marks pending, runs transcriber, saves completed")
    func testHappyPath() async throws {
        let transcriber = StubTranscriber(result: .success("Hello world"))
        let attachmentLoader = StubAttachmentLoader()
        let repository = StubTranscriptRepository()
        let writer = StubTranscriptWriter()

        let service = VoiceMemoTranscriptionService(
            transcriber: transcriber,
            attachmentLoader: attachmentLoader,
            transcriptRepository: repository,
            transcriptWriter: writer
        )

        await service.enqueueIfNeeded(
            messageId: "msg-1",
            conversationId: "conv-1",
            attachmentKey: "key-1",
            mimeType: "audio/m4a"
        )

        try await waitUntil(timeout: .seconds(10)) { await writer.completedSnapshot().count == 1 }

        let pendingCount = await writer.pendingSnapshot().count
        let completed = await writer.completedSnapshot()
        let failed = await writer.failedSnapshot()
        #expect(pendingCount == 1)
        #expect(completed.count == 1)
        #expect(failed.isEmpty)
        #expect(completed.first?.text == "Hello world")

        let transcribeCalls = await transcriber.callCount()
        let loadCalls = await attachmentLoader.callCount()
        #expect(transcribeCalls == 1)
        #expect(loadCalls == 1)
    }

    @Test("skips when an existing transcript is already stored")
    func testSkipsExistingCompletedTranscript() async throws {
        let transcriber = StubTranscriber(result: .success("ignored"))
        let attachmentLoader = StubAttachmentLoader()
        let repository = StubTranscriptRepository()
        await repository.set(
            VoiceMemoTranscript(
                messageId: "msg-1",
                conversationId: "conv-1",
                attachmentKey: "key-1",
                status: .completed,
                text: "Already done",
                createdAt: Date(),
                updatedAt: Date()
            )
        )
        let writer = StubTranscriptWriter()

        let service = VoiceMemoTranscriptionService(
            transcriber: transcriber,
            attachmentLoader: attachmentLoader,
            transcriptRepository: repository,
            transcriptWriter: writer
        )

        await service.enqueueIfNeeded(
            messageId: "msg-1",
            conversationId: "conv-1",
            attachmentKey: "key-1",
            mimeType: "audio/m4a"
        )

        // Give the actor a moment to settle.
        try await Task.sleep(for: .milliseconds(100))

        let pending = await writer.pendingSnapshot()
        let completed = await writer.completedSnapshot()
        let transcribeCalls = await transcriber.callCount()
        let loadCalls = await attachmentLoader.callCount()
        #expect(pending.isEmpty)
        #expect(completed.isEmpty)
        #expect(transcribeCalls == 0)
        #expect(loadCalls == 0)
    }

    @Test("does not auto-retry a previously failed transcript")
    func testSkipsFailedTranscriptOnNormalEnqueue() async throws {
        let transcriber = StubTranscriber(result: .success("ignored"))
        let attachmentLoader = StubAttachmentLoader()
        let repository = StubTranscriptRepository()
        await repository.set(
            VoiceMemoTranscript(
                messageId: "msg-1",
                conversationId: "conv-1",
                attachmentKey: "key-1",
                status: .failed,
                text: nil,
                errorDescription: "boom",
                createdAt: Date(),
                updatedAt: Date()
            )
        )
        let writer = StubTranscriptWriter()

        let service = VoiceMemoTranscriptionService(
            transcriber: transcriber,
            attachmentLoader: attachmentLoader,
            transcriptRepository: repository,
            transcriptWriter: writer
        )

        await service.enqueueIfNeeded(
            messageId: "msg-1",
            conversationId: "conv-1",
            attachmentKey: "key-1",
            mimeType: "audio/m4a"
        )

        try await Task.sleep(for: .milliseconds(100))

        let transcribeCalls = await transcriber.callCount()
        #expect(transcribeCalls == 0)
    }

    @Test("retry bypasses the failed-skip and runs the transcriber again")
    func testRetryBypassesFailedSkip() async throws {
        let transcriber = StubTranscriber(result: .success("Second attempt"))
        let attachmentLoader = StubAttachmentLoader()
        let repository = StubTranscriptRepository()
        await repository.set(
            VoiceMemoTranscript(
                messageId: "msg-1",
                conversationId: "conv-1",
                attachmentKey: "key-1",
                status: .failed,
                text: nil,
                errorDescription: "boom",
                createdAt: Date(),
                updatedAt: Date()
            )
        )
        let writer = StubTranscriptWriter()

        let service = VoiceMemoTranscriptionService(
            transcriber: transcriber,
            attachmentLoader: attachmentLoader,
            transcriptRepository: repository,
            transcriptWriter: writer
        )

        await service.retry(
            messageId: "msg-1",
            conversationId: "conv-1",
            attachmentKey: "key-1",
            mimeType: "audio/m4a"
        )

        try await waitUntil(timeout: .seconds(10)) { await writer.completedSnapshot().count == 1 }

        let completed = await writer.completedSnapshot()
        let transcribeCalls = await transcriber.callCount()
        #expect(transcribeCalls == 1)
        #expect(completed.first?.text == "Second attempt")
    }

    @Test("recoverable transcriber failures are written via saveFailed and surfaced as errorDescription")
    func testRecoverableFailurePathWritesFailed() async throws {
        let transcriber = StubTranscriber(
            result: .failure(VoiceMemoTranscriberError.audioFileUnreadable)
        )
        let attachmentLoader = StubAttachmentLoader()
        let repository = StubTranscriptRepository()
        let writer = StubTranscriptWriter()

        let service = VoiceMemoTranscriptionService(
            transcriber: transcriber,
            attachmentLoader: attachmentLoader,
            transcriptRepository: repository,
            transcriptWriter: writer
        )

        await service.enqueueIfNeeded(
            messageId: "msg-1",
            conversationId: "conv-1",
            attachmentKey: "key-1",
            mimeType: "audio/m4a"
        )

        try await waitUntil(timeout: .seconds(10)) { await writer.failedSnapshot().count == 1 }

        let failed = await writer.failedSnapshot()
        let pending = await writer.pendingSnapshot()
        let permanentlyFailed = await writer.permanentlyFailedSnapshot()
        #expect(pending.count == 1)
        #expect(failed.count == 1)
        #expect(failed.first?.errorDescription?.contains("read") == true)
        #expect(permanentlyFailed.isEmpty)
    }

    @Test("cancellation propagates to the transcriber so the SpeechAnalyzer pipeline stops")
    func testCancellationPropagatesToTranscriber() async throws {
        let transcriber = StubTranscriber(
            result: .failure(CancellationError())
        )
        let attachmentLoader = StubAttachmentLoader()
        let repository = StubTranscriptRepository()
        let writer = StubTranscriptWriter()

        let service = VoiceMemoTranscriptionService(
            transcriber: transcriber,
            attachmentLoader: attachmentLoader,
            transcriptRepository: repository,
            transcriptWriter: writer
        )

        await service.enqueueIfNeeded(
            messageId: "msg-1",
            conversationId: "conv-1",
            attachmentKey: "key-1",
            mimeType: "audio/m4a"
        )

        try await waitUntil(timeout: .seconds(10)) {
            await transcriber.cancelCallSnapshot().contains("msg-1")
        }

        let cancelCalls = await transcriber.cancelCallSnapshot()
        let permanentlyFailed = await writer.permanentlyFailedSnapshot()
        let failed = await writer.failedSnapshot()
        // The orchestrator told the transcriber to cancel its in-flight work,
        // and the cancellation arm did NOT persist a failure row — cancellation
        // is a transient state, not a recoverable or permanent failure.
        #expect(cancelCalls == ["msg-1"])
        #expect(permanentlyFailed.isEmpty)
        #expect(failed.isEmpty)
    }

    @Test("empty transcript is treated as permanent since retrying same audio produces same result")
    func testEmptyTranscriptIsPermanent() async throws {
        let transcriber = StubTranscriber(
            result: .failure(VoiceMemoTranscriberError.emptyTranscript)
        )
        let attachmentLoader = StubAttachmentLoader()
        let repository = StubTranscriptRepository()
        let writer = StubTranscriptWriter()

        let service = VoiceMemoTranscriptionService(
            transcriber: transcriber,
            attachmentLoader: attachmentLoader,
            transcriptRepository: repository,
            transcriptWriter: writer
        )

        await service.enqueueIfNeeded(
            messageId: "msg-1",
            conversationId: "conv-1",
            attachmentKey: "key-1",
            mimeType: "audio/m4a"
        )

        try await waitUntil(timeout: .seconds(10)) { await writer.permanentlyFailedSnapshot().count == 1 }

        let permanentlyFailed = await writer.permanentlyFailedSnapshot()
        let failed = await writer.failedSnapshot()
        #expect(permanentlyFailed.count == 1)
        #expect(permanentlyFailed.first?.messageId == "msg-1")
        #expect(failed.isEmpty)
    }

    @Test("permanent transcriber failures mark the row .permanentlyFailed so the scheduler skips it and the UI hides it")
    func testPermanentFailurePathMarksPermanentlyFailed() async throws {
        let transcriber = StubTranscriber(
            result: .failure(VoiceMemoTranscriberError.assetsUnavailable)
        )
        let attachmentLoader = StubAttachmentLoader()
        let repository = StubTranscriptRepository()
        let writer = StubTranscriptWriter()

        let service = VoiceMemoTranscriptionService(
            transcriber: transcriber,
            attachmentLoader: attachmentLoader,
            transcriptRepository: repository,
            transcriptWriter: writer
        )

        await service.enqueueIfNeeded(
            messageId: "msg-1",
            conversationId: "conv-1",
            attachmentKey: "key-1",
            mimeType: "audio/m4a"
        )

        try await waitUntil(timeout: .seconds(10)) { await writer.permanentlyFailedSnapshot().count == 1 }

        let permanentlyFailed = await writer.permanentlyFailedSnapshot()
        let failed = await writer.failedSnapshot()
        let deleted = await writer.deletedSnapshot()
        #expect(permanentlyFailed.count == 1)
        #expect(permanentlyFailed.first?.messageId == "msg-1")
        #expect(failed.isEmpty)
        #expect(deleted.isEmpty)
    }

    @Test("attachment loader failures are written via saveFailed without invoking the transcriber")
    func testAttachmentLoaderFailurePath() async throws {
        let transcriber = StubTranscriber(result: .success("never called"))
        let attachmentLoader = StubAttachmentLoader(error: StubError.boom)
        let repository = StubTranscriptRepository()
        let writer = StubTranscriptWriter()

        let service = VoiceMemoTranscriptionService(
            transcriber: transcriber,
            attachmentLoader: attachmentLoader,
            transcriptRepository: repository,
            transcriptWriter: writer
        )

        await service.enqueueIfNeeded(
            messageId: "msg-1",
            conversationId: "conv-1",
            attachmentKey: "key-1",
            mimeType: "audio/m4a"
        )

        try await waitUntil(timeout: .seconds(10)) { await writer.failedSnapshot().count == 1 }

        let transcribeCalls = await transcriber.callCount()
        let failed = await writer.failedSnapshot()
        #expect(transcribeCalls == 0)
        #expect(failed.count == 1)
    }

    @Test("two concurrent enqueueIfNeeded calls deduplicate by message id")
    func testConcurrentEnqueueDeduplicates() async throws {
        let transcriber = StubTranscriber(
            result: .success("Hello"),
            delay: .milliseconds(80)
        )
        let attachmentLoader = StubAttachmentLoader()
        let repository = StubTranscriptRepository()
        let writer = StubTranscriptWriter()

        let service = VoiceMemoTranscriptionService(
            transcriber: transcriber,
            attachmentLoader: attachmentLoader,
            transcriptRepository: repository,
            transcriptWriter: writer
        )

        async let firstCall: Void = service.enqueueIfNeeded(
            messageId: "msg-1",
            conversationId: "conv-1",
            attachmentKey: "key-1",
            mimeType: "audio/m4a"
        )
        async let secondCall: Void = service.enqueueIfNeeded(
            messageId: "msg-1",
            conversationId: "conv-1",
            attachmentKey: "key-1",
            mimeType: "audio/m4a"
        )
        _ = await (firstCall, secondCall)

        try await waitUntil(timeout: .seconds(10)) { await writer.completedSnapshot().count == 1 }

        let transcribeCalls = await transcriber.callCount()
        let loadCalls = await attachmentLoader.callCount()
        let pending = await writer.pendingSnapshot()
        let completed = await writer.completedSnapshot()
        #expect(transcribeCalls == 1)
        #expect(loadCalls == 1)
        #expect(pending.count == 1)
        #expect(completed.count == 1)
    }
}

// MARK: - Helpers

private enum StubError: Error {
    case boom
}

// MARK: - Stubs

private actor StubTranscriber: VoiceMemoTranscribing {
    private let result: Result<String, Error>
    private let delay: Duration
    private var calls: Int = 0
    private var cancelCalls: [String] = []

    init(result: Result<String, Error>, delay: Duration = .zero) {
        self.result = result
        self.delay = delay
    }

    func callCount() -> Int { calls }
    func cancelCallSnapshot() -> [String] { cancelCalls }

    func transcribe(messageId: String, fileURL: URL) async throws -> String {
        calls += 1
        if delay > .zero {
            try? await Task.sleep(for: delay)
        }
        return try result.get()
    }

    func cancel(messageId: String) async {
        cancelCalls.append(messageId)
    }
}

private actor StubAttachmentLoader: RemoteAttachmentLoaderProtocol {
    private let payload: Data
    private let mimeType: String
    private let error: Error?
    private var calls: Int = 0

    init(
        payload: Data = Data([0x00, 0x01]),
        mimeType: String = "audio/m4a",
        error: Error? = nil
    ) {
        self.payload = payload
        self.mimeType = mimeType
        self.error = error
    }

    func callCount() -> Int { calls }

    func loadImageData(from storedJSON: String) async throws -> Data {
        try await loadAttachmentData(from: storedJSON).data
    }

    func loadAttachmentData(from storedJSON: String) async throws -> LoadedAttachment {
        calls += 1
        if let error {
            throw error
        }
        return LoadedAttachment(data: payload, mimeType: mimeType, filename: nil)
    }
}

private actor StubTranscriptRepository: VoiceMemoTranscriptRepositoryProtocol {
    private var byMessageId: [String: VoiceMemoTranscript] = [:]

    func set(_ transcript: VoiceMemoTranscript) {
        byMessageId[transcript.messageId] = transcript
    }

    nonisolated func transcriptPublisher(for messageId: String) -> AnyPublisher<VoiceMemoTranscript?, Never> {
        Just(nil).eraseToAnyPublisher()
    }

    nonisolated func transcriptsPublisher(in conversationId: String) -> AnyPublisher<[String: VoiceMemoTranscript], Never> {
        Just([:]).eraseToAnyPublisher()
    }

    nonisolated func fetchAllTranscripts(in conversationId: String) throws -> [String: VoiceMemoTranscript] {
        [:]
    }

    func transcript(for messageId: String) async throws -> VoiceMemoTranscript? {
        byMessageId[messageId]
    }
}

private actor StubTranscriptWriter: VoiceMemoTranscriptWriterProtocol {
    private(set) var pending: [VoiceMemoTranscript] = []
    private(set) var completed: [VoiceMemoTranscript] = []
    private(set) var failed: [VoiceMemoTranscript] = []
    private(set) var permanentlyFailed: [VoiceMemoTranscript] = []
    private(set) var deletedMessageIds: [String] = []

    func pendingSnapshot() -> [VoiceMemoTranscript] { pending }
    func completedSnapshot() -> [VoiceMemoTranscript] { completed }
    func failedSnapshot() -> [VoiceMemoTranscript] { failed }
    func permanentlyFailedSnapshot() -> [VoiceMemoTranscript] { permanentlyFailed }
    func deletedSnapshot() -> [String] { deletedMessageIds }

    func markPending(messageId: String, conversationId: String, attachmentKey: String) async throws {
        pending.append(
            VoiceMemoTranscript(
                messageId: messageId,
                conversationId: conversationId,
                attachmentKey: attachmentKey,
                status: .pending,
                createdAt: Date(),
                updatedAt: Date()
            )
        )
    }

    func saveCompleted(
        messageId: String,
        conversationId: String,
        attachmentKey: String,
        text: String
    ) async throws {
        completed.append(
            VoiceMemoTranscript(
                messageId: messageId,
                conversationId: conversationId,
                attachmentKey: attachmentKey,
                status: .completed,
                text: text,
                createdAt: Date(),
                updatedAt: Date()
            )
        )
    }

    func saveFailed(
        messageId: String,
        conversationId: String,
        attachmentKey: String,
        errorDescription: String?
    ) async throws {
        failed.append(
            VoiceMemoTranscript(
                messageId: messageId,
                conversationId: conversationId,
                attachmentKey: attachmentKey,
                status: .failed,
                text: nil,
                errorDescription: errorDescription,
                createdAt: Date(),
                updatedAt: Date()
            )
        )
    }

    func markPermanentlyFailed(
        messageId: String,
        conversationId: String,
        attachmentKey: String,
        errorDescription: String?
    ) async throws {
        permanentlyFailed.append(
            VoiceMemoTranscript(
                messageId: messageId,
                conversationId: conversationId,
                attachmentKey: attachmentKey,
                status: .permanentlyFailed,
                text: nil,
                errorDescription: errorDescription,
                createdAt: Date(),
                updatedAt: Date()
            )
        )
    }

    func deleteTranscript(messageId: String) async throws {
        deletedMessageIds.append(messageId)
        pending.removeAll { $0.messageId == messageId }
        failed.removeAll { $0.messageId == messageId }
        completed.removeAll { $0.messageId == messageId }
        permanentlyFailed.removeAll { $0.messageId == messageId }
    }
}
