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

        try await waitUntil(timeout: .seconds(2)) { await writer.completedSnapshot().count == 1 }

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

        try await waitUntil(timeout: .seconds(2)) { await writer.completedSnapshot().count == 1 }

        let completed = await writer.completedSnapshot()
        let transcribeCalls = await transcriber.callCount()
        #expect(transcribeCalls == 1)
        #expect(completed.first?.text == "Second attempt")
    }

    @Test("transcriber failures are written via saveFailed and surfaced as errorDescription")
    func testFailurePathWritesFailed() async throws {
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

        try await waitUntil(timeout: .seconds(2)) { await writer.failedSnapshot().count == 1 }

        let failed = await writer.failedSnapshot()
        let pending = await writer.pendingSnapshot()
        #expect(pending.count == 1)
        #expect(failed.count == 1)
        #expect(failed.first?.errorDescription?.contains("empty") == true)
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

        try await waitUntil(timeout: .seconds(2)) { await writer.failedSnapshot().count == 1 }

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

        try await waitUntil(timeout: .seconds(2)) { await writer.completedSnapshot().count == 1 }

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

    init(result: Result<String, Error>, delay: Duration = .zero) {
        self.result = result
        self.delay = delay
    }

    func callCount() -> Int { calls }

    func transcribe(messageId: String, fileURL: URL) async throws -> String {
        calls += 1
        if delay > .zero {
            try? await Task.sleep(for: delay)
        }
        return try result.get()
    }

    func cancel(messageId: String) async {}
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

    func transcript(for messageId: String) async throws -> VoiceMemoTranscript? {
        byMessageId[messageId]
    }
}

private actor StubTranscriptWriter: VoiceMemoTranscriptWriterProtocol {
    private(set) var pending: [VoiceMemoTranscript] = []
    private(set) var completed: [VoiceMemoTranscript] = []
    private(set) var failed: [VoiceMemoTranscript] = []

    func pendingSnapshot() -> [VoiceMemoTranscript] { pending }
    func completedSnapshot() -> [VoiceMemoTranscript] { completed }
    func failedSnapshot() -> [VoiceMemoTranscript] { failed }

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
}
