import Foundation

/// Errors that can occur during background uploads
public enum BackgroundUploadError: Error, Sendable, Equatable {
    case networkError(String)
    case httpError(statusCode: Int)
    case cancelled
    case unknown(String)

    public var localizedDescription: String {
        switch self {
        case .networkError(let message):
            return "Network error: \(message)"
        case .httpError(let statusCode):
            return "HTTP error: \(statusCode)"
        case .cancelled:
            return "Upload cancelled"
        case .unknown(let message):
            return "Unknown error: \(message)"
        }
    }
}

/// Result of a background upload operation
public struct BackgroundUploadResult: Sendable, Equatable {
    public let taskId: String
    public let error: BackgroundUploadError?

    public var success: Bool { error == nil }

    public init(taskId: String, error: BackgroundUploadError? = nil) {
        self.taskId = taskId
        self.error = error
    }

    public static func success(taskId: String) -> BackgroundUploadResult {
        BackgroundUploadResult(taskId: taskId)
    }

    public static func failure(taskId: String, error: BackgroundUploadError) -> BackgroundUploadResult {
        BackgroundUploadResult(taskId: taskId, error: error)
    }
}

public protocol BackgroundUploadManagerProtocol: Sendable {
    /// Start a background upload task
    /// - Parameters:
    ///   - fileURL: URL to the file to upload (must be in persistent location, not temp)
    ///   - uploadURL: Presigned S3 URL
    ///   - contentType: MIME type
    ///   - taskId: Unique identifier for tracking (stored in URLSessionTask.taskDescription)
    /// - Returns: The task identifier
    func startUpload(
        fileURL: URL,
        uploadURL: URL,
        contentType: String,
        taskId: String
    ) async throws

    /// Cancel an in-progress upload
    func cancelUpload(taskId: String) async

    /// Called when app receives background URLSession events
    func handleEventsForBackgroundURLSession(
        identifier: String,
        completionHandler: @escaping @Sendable () -> Void
    ) async

    /// Wait for a specific upload task to complete
    /// - Parameter taskId: The task identifier from startUpload
    /// - Returns: The upload result
    func waitForCompletion(taskId: String) async -> BackgroundUploadResult

    /// Stream of upload completions (task ID, success/failure)
    /// Note: This is a single-consumer stream. For multiple consumers, use waitForCompletion instead.
    var uploadCompletions: AsyncStream<BackgroundUploadResult> { get }
}
