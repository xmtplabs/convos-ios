import Foundation

public struct MockUploadRequest: Sendable {
    public let fileURL: URL
    public let uploadURL: URL
    public let contentType: String
    public let taskId: String
}

public final class MockBackgroundUploadManager: BackgroundUploadManagerProtocol, @unchecked Sendable {
    private let lock: NSLock = NSLock()
    private var continuation: AsyncStream<BackgroundUploadResult>.Continuation?
    private var _startedUploads: [MockUploadRequest] = []
    private var _cancelledTaskIds: [String] = []
    private var taskContinuations: [String: CheckedContinuation<BackgroundUploadResult, Never>] = [:]
    private var completedResults: [String: BackgroundUploadResult] = [:]

    public var startedUploads: [MockUploadRequest] {
        lock.withLock { _startedUploads }
    }

    public var cancelledTaskIds: [String] {
        lock.withLock { _cancelledTaskIds }
    }

    public init() {}

    public var uploadCompletions: AsyncStream<BackgroundUploadResult> {
        AsyncStream { continuation in
            self.lock.withLock { self.continuation = continuation }
        }
    }

    public func startUpload(
        fileURL: URL,
        uploadURL: URL,
        contentType: String,
        taskId: String
    ) async throws {
        let request = MockUploadRequest(
            fileURL: fileURL,
            uploadURL: uploadURL,
            contentType: contentType,
            taskId: taskId
        )
        lock.withLock { _startedUploads.append(request) }
        lock.withLock { continuation?.yield(.success(taskId: taskId)) }
    }

    public func cancelUpload(taskId: String) async {
        lock.withLock { _cancelledTaskIds.append(taskId) }
    }

    public func handleEventsForBackgroundURLSession(
        identifier: String,
        completionHandler: @escaping @Sendable () -> Void
    ) async {
        completionHandler()
    }

    public func waitForCompletion(taskId: String) async -> BackgroundUploadResult {
        // Check if result already available
        let existingResult: BackgroundUploadResult? = lock.withLock {
            if let result = completedResults[taskId] {
                completedResults.removeValue(forKey: taskId)
                return result
            }
            return nil
        }

        if let result = existingResult {
            return result
        }

        // Wait for completion via continuation
        return await withCheckedContinuation { continuation in
            lock.withLock {
                if let result = completedResults[taskId] {
                    completedResults.removeValue(forKey: taskId)
                    continuation.resume(returning: result)
                } else {
                    taskContinuations[taskId] = continuation
                }
            }
        }
    }

    public func simulateUploadCompletion(taskId: String, error: BackgroundUploadError? = nil) {
        let result: BackgroundUploadResult = if let error {
            .failure(taskId: taskId, error: error)
        } else {
            .success(taskId: taskId)
        }

        // Notify per-taskId waiter if one exists, otherwise store for later
        let taskContinuation: CheckedContinuation<BackgroundUploadResult, Never>? = lock.withLock {
            if let cont = taskContinuations[taskId] {
                taskContinuations.removeValue(forKey: taskId)
                return cont
            } else {
                completedResults[taskId] = result
                return nil
            }
        }

        if let taskContinuation {
            taskContinuation.resume(returning: result)
        }

        // Also yield to the legacy stream
        lock.withLock { continuation?.yield(result) }
    }
}
