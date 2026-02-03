import Foundation

public enum BackendAuthSkippedError: Error, LocalizedError {
    case operationNotAvailable(operation: String)

    public var errorDescription: String? {
        switch self {
        case .operationNotAvailable(let operation):
            return "Backend operation '\(operation)' not available when skipBackendAuth is enabled"
        }
    }
}

public final class NoOpAPIClient: ConvosAPIClientProtocol, @unchecked Sendable {
    public init() {}

    public func request(
        for path: String,
        method: String,
        queryParameters: [String: String]?
    ) throws -> URLRequest {
        throw BackendAuthSkippedError.operationNotAvailable(operation: "request")
    }

    public func registerDevice(deviceId: String, pushToken: String?) async throws {
        throw BackendAuthSkippedError.operationNotAvailable(operation: "registerDevice")
    }

    public func authenticate(appCheckToken: String, retryCount: Int) async throws -> String {
        throw BackendAuthSkippedError.operationNotAvailable(operation: "authenticate")
    }

    public func uploadAttachment(
        data: Data,
        filename: String,
        contentType: String,
        acl: String
    ) async throws -> String {
        throw BackendAuthSkippedError.operationNotAvailable(operation: "uploadAttachment")
    }

    public func uploadAttachmentAndExecute(
        data: Data,
        filename: String,
        afterUpload: @escaping (String) async throws -> Void
    ) async throws -> String {
        throw BackendAuthSkippedError.operationNotAvailable(operation: "uploadAttachmentAndExecute")
    }

    public func subscribeToTopics(deviceId: String, clientId: String, topics: [String]) async throws {
        throw BackendAuthSkippedError.operationNotAvailable(operation: "subscribeToTopics")
    }

    public func unsubscribeFromTopics(clientId: String, topics: [String]) async throws {
        throw BackendAuthSkippedError.operationNotAvailable(operation: "unsubscribeFromTopics")
    }

    public func unregisterInstallation(clientId: String) async throws {
        throw BackendAuthSkippedError.operationNotAvailable(operation: "unregisterInstallation")
    }
}
