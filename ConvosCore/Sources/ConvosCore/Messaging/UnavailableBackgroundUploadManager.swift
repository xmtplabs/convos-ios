import Foundation

/// A BackgroundUploadManager implementation for contexts where photo uploads are not supported.
/// Unlike MockBackgroundUploadManager (used for testing), this throws clear errors if called.
public final class UnavailableBackgroundUploadManager: BackgroundUploadManagerProtocol, Sendable {
    public enum UnavailableError: Error, LocalizedError {
        case photoUploadsNotSupported

        public var errorDescription: String? {
            "Photo uploads are not supported in this context (draft conversation)"
        }
    }

    public init() {}

    public var uploadCompletions: AsyncStream<BackgroundUploadResult> {
        AsyncStream { $0.finish() }
    }

    public func startUpload(
        fileURL: URL,
        uploadURL: URL,
        contentType: String,
        taskId: String
    ) async throws {
        throw UnavailableError.photoUploadsNotSupported
    }

    public func cancelUpload(taskId: String) async {
        // No-op - nothing to cancel
    }

    public func handleEventsForBackgroundURLSession(
        identifier: String,
        completionHandler: @escaping @Sendable () -> Void
    ) async {
        completionHandler()
    }

    public func waitForCompletion(taskId: String) async -> BackgroundUploadResult {
        .failure(taskId: taskId, error: .unknown("Photo uploads not supported in this context"))
    }
}
