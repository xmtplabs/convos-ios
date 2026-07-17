import ConvosCore
import Foundation

/// Spike-only foreground uploader for the share extension.
///
/// The shipping `BackgroundUploadManager` uses a background `URLSession`, which
/// inside an app extension needs `sharedContainerIdentifier` set to the app
/// group, a process-unique session identifier, and cross-process completion
/// handling (the app is relaunched to finish uploads after the extension dies).
/// That is the production plumbing to add. While the share sheet is on screen
/// the extension stays alive, so a plain foreground PUT is enough to prove the
/// attachment send path works end to end.
final class ForegroundUploadManager: BackgroundUploadManagerProtocol, @unchecked Sendable {
    private let session: URLSession = .shared
    private let lock: NSLock = NSLock()
    private var results: [String: BackgroundUploadResult] = [:]
    private var continuation: AsyncStream<BackgroundUploadResult>.Continuation?

    lazy var uploadCompletions: AsyncStream<BackgroundUploadResult> = AsyncStream { continuation in
        self.continuation = continuation
    }

    func startUpload(fileURL: URL, uploadURL: URL, contentType: String, taskId: String) async throws {
        var request: URLRequest = URLRequest(url: uploadURL)
        request.httpMethod = "PUT"
        request.setValue(contentType, forHTTPHeaderField: "Content-Type")

        let result: BackgroundUploadResult
        do {
            let (_, response) = try await session.upload(for: request, fromFile: fileURL)
            if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
                result = .failure(taskId: taskId, error: .httpError(statusCode: http.statusCode))
            } else {
                result = .success(taskId: taskId)
            }
        } catch {
            result = .failure(taskId: taskId, error: .networkError(error.localizedDescription))
        }

        lock.withLock { results[taskId] = result }
        continuation?.yield(result)
    }

    func cancelUpload(taskId: String) async {}

    func handleEventsForBackgroundURLSession(
        identifier: String,
        completionHandler: @escaping @Sendable () -> Void
    ) async {
        completionHandler()
    }

    func waitForCompletion(taskId: String) async -> BackgroundUploadResult {
        for _ in 0..<600 {
            if let stored = lock.withLock({ results[taskId] }) {
                return stored
            }
            try? await Task.sleep(nanoseconds: 50_000_000)
        }
        return .failure(taskId: taskId, error: .unknown("upload timed out"))
    }
}
