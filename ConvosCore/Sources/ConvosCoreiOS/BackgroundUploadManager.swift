#if canImport(UIKit)
import ConvosCore
import Foundation

public final class BackgroundUploadManager: NSObject, BackgroundUploadManagerProtocol, @unchecked Sendable {
    public static let shared: BackgroundUploadManager = BackgroundUploadManager()

    public static let sessionIdentifier: String = "com.convos.backgroundUpload"

    // swiftlint:disable:next implicitly_unwrapped_optional
    private var backgroundSession: URLSession!
    private let lock: NSLock = NSLock()

    private var backgroundCompletionHandler: (@Sendable () -> Void)?

    private var uploadCompletionsContinuation: AsyncStream<BackgroundUploadResult>.Continuation?
    public private(set) lazy var uploadCompletions: AsyncStream<BackgroundUploadResult> = {
        AsyncStream { continuation in
            self.uploadCompletionsContinuation = continuation
        }
    }()

    /// Per-taskId continuations for waitForCompletion
    private var taskContinuations: [String: CheckedContinuation<BackgroundUploadResult, Never>] = [:]
    /// Results for tasks that completed before waitForCompletion was called
    private var completedResults: [String: BackgroundUploadResult] = [:]

    private override init() {
        super.init()

        let config = URLSessionConfiguration.background(withIdentifier: Self.sessionIdentifier)
        config.isDiscretionary = false
        config.sessionSendsLaunchEvents = true
        config.allowsCellularAccess = true
        config.shouldUseExtendedBackgroundIdleMode = true

        backgroundSession = URLSession(
            configuration: config,
            delegate: self,
            delegateQueue: nil
        )
    }

    public func startUpload(
        fileURL: URL,
        uploadURL: URL,
        contentType: String,
        taskId: String
    ) async throws {
        var request = URLRequest(url: uploadURL)
        request.httpMethod = "PUT"
        request.setValue(contentType, forHTTPHeaderField: "Content-Type")

        let task = backgroundSession.uploadTask(with: request, fromFile: fileURL)
        task.taskDescription = taskId
        task.resume()

        Log.debug("Started background upload task \(task.taskIdentifier) for \(taskId)")
    }

    public func cancelUpload(taskId: String) async {
        let tasks = await backgroundSession.allTasks
        if let task = tasks.first(where: { $0.taskDescription == taskId }) {
            task.cancel()
            Log.debug("Cancelled upload task \(taskId)")
        }
    }

    public func handleEventsForBackgroundURLSession(
        identifier: String,
        completionHandler: @escaping @Sendable () -> Void
    ) async {
        guard identifier == Self.sessionIdentifier else {
            completionHandler()
            return
        }

        lock.withLock {
            backgroundCompletionHandler = completionHandler
        }

        Log.debug("Handling background URLSession events for \(identifier)")
    }

    public func waitForCompletion(taskId: String) async -> BackgroundUploadResult {
        // Check if result already available (upload completed before we started waiting)
        let existingResult: BackgroundUploadResult? = lock.withLock {
            if let result = completedResults[taskId] {
                completedResults.removeValue(forKey: taskId)
                return result
            }
            return nil
        }

        if let result = existingResult {
            Log.debug("waitForCompletion: Found existing result for \(taskId)")
            return result
        }

        // Wait for completion via continuation
        Log.debug("waitForCompletion: Waiting for \(taskId)")
        return await withCheckedContinuation { continuation in
            lock.withLock {
                // Double-check in case result arrived between check and continuation setup
                if let result = completedResults[taskId] {
                    completedResults.removeValue(forKey: taskId)
                    continuation.resume(returning: result)
                } else {
                    taskContinuations[taskId] = continuation
                }
            }
        }
    }
}

extension BackgroundUploadManager: URLSessionTaskDelegate, URLSessionDataDelegate {
    public func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        didSendBodyData bytesSent: Int64,
        totalBytesSent: Int64,
        totalBytesExpectedToSend: Int64
    ) {
        guard let taskId = task.taskDescription else { return }

        let percentage = totalBytesExpectedToSend > 0
            ? Double(totalBytesSent) / Double(totalBytesExpectedToSend)
            : 0.0
        PhotoUploadProgressTracker.shared.setProgress(
            stage: .uploading,
            percentage: percentage,
            for: taskId
        )
    }

    public func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        didCompleteWithError error: Error?
    ) {
        guard let taskId = task.taskDescription else { return }

        let result: BackgroundUploadResult
        if let error {
            Log.error("Background upload failed for \(taskId): \(error)")
            PhotoUploadProgressTracker.shared.setStage(.failed, for: taskId)
            let uploadError: BackgroundUploadError = if (error as NSError).domain == NSURLErrorDomain,
                                                        (error as NSError).code == NSURLErrorCancelled {
                .cancelled
            } else {
                .networkError(error.localizedDescription)
            }
            result = .failure(taskId: taskId, error: uploadError)
        } else if let httpResponse = task.response as? HTTPURLResponse, httpResponse.statusCode == 200 {
            Log.debug("Background upload completed for \(taskId)")
            result = .success(taskId: taskId)
        } else {
            let statusCode = (task.response as? HTTPURLResponse)?.statusCode ?? -1
            Log.error("Background upload failed with status \(statusCode) for \(taskId)")
            PhotoUploadProgressTracker.shared.setStage(.failed, for: taskId)
            result = .failure(taskId: taskId, error: .httpError(statusCode: statusCode))
        }

        // Notify per-taskId waiter if one exists, otherwise store for later retrieval
        let continuation: CheckedContinuation<BackgroundUploadResult, Never>? = lock.withLock {
            if let cont = taskContinuations[taskId] {
                taskContinuations.removeValue(forKey: taskId)
                return cont
            } else {
                // No waiter yet - store result for when waitForCompletion is called
                completedResults[taskId] = result
                return nil
            }
        }

        if let continuation {
            Log.debug("Background upload notifying waiter for \(taskId)")
            continuation.resume(returning: result)
        }

        // Also yield to the stream for any legacy consumers
        uploadCompletionsContinuation?.yield(result)
    }

    public func urlSessionDidFinishEvents(forBackgroundURLSession session: URLSession) {
        lock.lock()
        defer { lock.unlock() }
        let handler = backgroundCompletionHandler
        backgroundCompletionHandler = nil

        if let handler {
            DispatchQueue.main.async {
                handler()
            }
        }
    }
}
#endif
