import ConvosLogging
import Foundation

protocol ConvosAPIClientFactoryType {
    static func client(environment: AppEnvironment, overrideJWTToken: String?) -> any ConvosAPIClientProtocol
}

enum ConvosAPIClientFactory: ConvosAPIClientFactoryType {
    static func client(environment: AppEnvironment, overrideJWTToken: String? = nil) -> any ConvosAPIClientProtocol {
        ConvosAPIClient(environment: environment, overrideJWTToken: overrideJWTToken)
    }
}

public protocol ConvosAPIClientProtocol: AnyObject, Sendable {
    func request(for path: String,
                 method: String,
                 queryParameters: [String: String]?) throws -> URLRequest

    /// Register device with AppCheck authentication (no JWT required - device-level operation)
    func registerDevice(deviceId: String, pushToken: String?) async throws

    func authenticate(appCheckToken: String,
                      retryCount: Int) async throws -> String

    func uploadAttachment(
        data: Data,
        filename: String,
        contentType: String,
        acl: String
    ) async throws -> String
    func uploadAttachmentAndExecute(
        data: Data,
        filename: String,
        afterUpload: @escaping (String) async throws -> Void
    ) async throws -> String

    // Push notifications
    func subscribeToTopics(deviceId: String, clientId: String, topics: [String]) async throws
    func unsubscribeFromTopics(clientId: String, topics: [String]) async throws
    func unregisterInstallation(clientId: String) async throws
}

/// HTTP client for Convos backend API
///
/// ConvosAPIClient provides both authenticated and unauthenticated access to the Convos backend, handling:
/// - JWT authentication with automatic token refresh
/// - Device registration with Firebase AppCheck
/// - Attachment uploads via S3 presigned URLs
/// - Push notification topic subscriptions
/// - Device and installation management
/// - Exponential backoff retry logic
///
/// The client automatically re-authenticates on 401 responses up to a maximum
/// retry count and stores JWT tokens in keychain for persistence.
final class ConvosAPIClient: ConvosAPIClientProtocol, Sendable {
    private let baseURL: URL
    private let session: URLSession
    private let environment: AppEnvironment
    private let keychainService: any KeychainServiceProtocol = KeychainService()
    private let overrideJWTToken: String?  // Immutable JWT override from APNS payload
    private let maxRetryCount: Int = 3

    fileprivate init(environment: AppEnvironment, overrideJWTToken: String? = nil) {
        guard let apiBaseURL = URL(string: environment.apiBaseURL) else {
            fatalError("Failed constructing API base URL")
        }
        self.baseURL = apiBaseURL
        self.session = URLSession(configuration: .default)
        self.environment = environment
        self.overrideJWTToken = overrideJWTToken
    }

    // MARK: - Base Request Building

    func request(for path: String,
                 method: String = "GET",
                 queryParameters: [String: String]? = nil) throws -> URLRequest {
        var urlComponents = URLComponents(url: baseURL.appendingPathComponent(path), resolvingAgainstBaseURL: false)
        if let queryParameters = queryParameters {
            urlComponents?.queryItems = queryParameters.map { URLQueryItem(name: $0.key, value: $0.value) }
        }

        guard let url = urlComponents?.url else {
            throw APIError.invalidURL
        }

        var request = URLRequest(url: url)
        request.httpMethod = method
        return request
    }

    /// Register device using AppCheck authentication
    /// This is a device-level operation, not inbox-specific
    func registerDevice(deviceId: String, pushToken: String?) async throws {
        let url = baseURL.appendingPathComponent("v2/device/register")
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        // Get AppCheck token for authentication
        let appCheckToken = try await FirebaseHelperCore.getAppCheckToken()
        request.setValue(appCheckToken, forHTTPHeaderField: "X-Firebase-AppCheck")

        // Determine APNS environment and token type
        let apnsEnv: String?
        let pushTokenType: String?
        if let token = pushToken, !token.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            apnsEnv = environment.apnsEnvironment == .sandbox ? "sandbox" : "production"
            pushTokenType = "apns"
        } else {
            apnsEnv = nil
            pushTokenType = nil
        }

        let body = ConvosAPI.RegisterDeviceRequest(
            deviceId: deviceId,
            pushToken: pushToken,
            pushTokenType: pushTokenType,
            apnsEnv: apnsEnv
        )
        request.httpBody = try JSONEncoder().encode(body)

        let (data, response) = try await session.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw APIError.invalidResponse
        }

        guard (200...299).contains(httpResponse.statusCode) else {
            let errorMessage = String(data: data, encoding: .utf8) ?? "Unknown error"
            Log.error("Device registration failed with status \(httpResponse.statusCode): \(errorMessage)")
            throw APIError.serverError(errorMessage)
        }

        Log.info("Device registered successfully (token: \(pushToken != nil ? "present" : "nil"))")
    }

    // MARK: - Private Helpers

    private func reAuthenticate() async throws -> String {
        let firebaseAppCheckToken = try await FirebaseHelperCore.getAppCheckToken()
        return try await authenticate(
            appCheckToken: firebaseAppCheckToken,
            retryCount: 0
        )
    }

    // MARK: - Authentication

    /// Authenticates with the backend to obtain a JWT token
    /// - Parameters:
    ///   - appCheckToken: Firebase AppCheck token for authentication
    ///   - retryCount: Number of retry attempts (for rate limiting)
    /// - Returns: JWT token string
    func authenticate(appCheckToken: String,
                      retryCount: Int = 0) async throws -> String {
        let url = baseURL.appendingPathComponent("v2/auth/token")
        var request = URLRequest(url: url)
        request.httpMethod = "POST"

        request.setValue(appCheckToken, forHTTPHeaderField: "X-Firebase-AppCheck")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        struct AuthRequest: Encodable {
            let deviceId: String
        }

        let deviceId = DeviceInfo.deviceIdentifier
        let requestBody = AuthRequest(deviceId: deviceId)
        request.httpBody = try JSONEncoder().encode(requestBody)

        let (data, response) = try await session.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw APIError.authenticationFailed
        }

        // Handle bad request
        if httpResponse.statusCode == 400 {
            throw APIError.badRequest(parseErrorMessage(from: data))
        }

        // Handle auth rate limiting
        if httpResponse.statusCode == 429 {
            guard retryCount < maxRetryCount else {
                throw APIError.rateLimitExceeded
            }
            // Use exponential backoff for rate limit retries
            let delay = TimeInterval.calculateExponentialBackoff(for: retryCount)
            Log.info("Auth rate limited - retrying in \(delay)s (attempt \(retryCount + 1) of \(maxRetryCount))")

            // Sleep and then retry
            try await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            return try await authenticate(appCheckToken: appCheckToken,
                                          retryCount: retryCount + 1)
        }

        guard httpResponse.statusCode == 200 else {
            let errorMessage = parseErrorMessage(from: data)
            Log.error("Authentication failed with status \(httpResponse.statusCode): \(errorMessage ?? "unknown error")")
            throw APIError.authenticationFailed
        }

        struct AuthResponse: Codable {
            let token: String
        }

        let authResponse = try JSONDecoder().decode(AuthResponse.self, from: data)
        try keychainService.saveString(
            authResponse.token,
            account: KeychainAccount.jwt(deviceId: deviceId)
        )
        Log.info("Successfully authenticated and stored JWT token")
        return authResponse.token
    }

    // MARK: - Private Helpers

    private func authenticatedRequest(
        for path: String,
        method: String = "GET",
        queryParameters: [String: String]? = nil
    ) throws -> URLRequest {
        var request = try request(for: path, method: method, queryParameters: queryParameters)

        let deviceId = DeviceInfo.deviceIdentifier

        // Prioritize override JWT token (from notification payload) over keychain JWT
        if let overrideJWT = overrideJWTToken {
            Log.debug("Using override JWT token from notification payload")
            request.setValue(overrideJWT, forHTTPHeaderField: "X-Convos-AuthToken")
        } else {
            // No override JWT - try keychain
            do {
                if let keychainJWT = try keychainService.retrieveString(
                    account: KeychainAccount.jwt(deviceId: deviceId)
                ) {
                    Log.debug("Using JWT token from keychain")
                    request.setValue(keychainJWT, forHTTPHeaderField: "X-Convos-AuthToken")
                } else {
                    Log.debug("No JWT token found - request will trigger re-authentication")
                }
            } catch {
                Log.warning("Failed to retrieve JWT from keychain: \(error.localizedDescription)")
                // In main app context, continue without JWT - will trigger re-authentication
            }
        }

        return request
    }

    private func performRequest<T: Decodable>(_ request: URLRequest, retryCount: Int = 0) async throws -> T {
        do {
            let (data, response) = try await session.data(for: request)

            Log.info("\(request.url?.path(percentEncoded: false) ?? "nil") received response: \(data.prettyPrintedJSONString ?? "nil data")")

            guard let httpResponse = response as? HTTPURLResponse else {
                throw APIError.invalidResponse
            }

            switch httpResponse.statusCode {
            case 200...203, 206...299:
                if T.self == EmptyResponse.self,
                   let emptyResponse = EmptyResponse() as? T {
                    return emptyResponse
                } else {
                    let decoder = JSONDecoder()
                    decoder.dateDecodingStrategy = .iso8601
                    return try decoder.decode(T.self, from: data)
                }
            case 204, 205, 304:
                // Handle no content responses
                if T.self == EmptyResponse.self,
                   let emptyResponse = EmptyResponse() as? T {
                    return emptyResponse
                } else if let emptyDict = [:] as? T {
                    return emptyDict
                } else if let emptyArray = [] as? T {
                    return emptyArray
                } else {
                    // For other types, throw appropriate error
                    throw APIError.noContent
                }
            case 400:
                // Parse error message from response if available
                let errorMessage: String?
                if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                   let message = json["message"] as? String {
                    errorMessage = message
                } else {
                    errorMessage = String(data: data, encoding: .utf8)
                }
                throw APIError.badRequest(errorMessage)
            case 401:
                // When using JWT override, never attempt re-authentication
                // (AppCheck not available when using JWT from APNS payload)
                guard overrideJWTToken == nil else {
                    Log.error("Authentication failed in JWT override mode - cannot re-authenticate without AppCheck")
                    throw APIError.notAuthenticated
                }

                // Check if we've exceeded max retries
                guard retryCount < maxRetryCount else {
                    Log.error("Max retry count (\(maxRetryCount)) exceeded for request")
                    throw APIError.notAuthenticated
                }

                // Try to re-authenticate and retry the request
                do {
                    Log.info("Attempting re-authentication (attempt \(retryCount + 1) of \(maxRetryCount))")
                    let freshJWT = try await reAuthenticate()
                    guard !freshJWT.isEmpty else {
                        throw APIError.notAuthenticated
                    }
                    // Create a new request with the fresh token
                    var newRequest = request
                    newRequest.setValue(freshJWT, forHTTPHeaderField: "X-Convos-AuthToken")
                    // Retry the request with incremented retry count
                    return try await performRequest(newRequest, retryCount: retryCount + 1)
                } catch {
                    Log.error("Re-authentication failed: \(error.localizedDescription)")
                    throw APIError.notAuthenticated
                }
            case 403:
                throw APIError.forbidden
            case 404:
                throw APIError.notFound
            default:
                let errorMessage = String(data: data, encoding: .utf8)
                throw APIError.serverError(errorMessage)
            }
        } catch {
            throw error
        }
    }

    func uploadAttachment(
        data: Data,
        filename: String,
        contentType: String = "image/jpeg",
        acl: String = "public-read"
    ) async throws -> String {
        Log.info("Starting attachment upload process for file: \(filename)")
        Log.info("File data size: \(data.count) bytes")

        // Get presigned URL from Convos API
        let presignedRequest = try authenticatedRequest(
            for: "v2/attachments/presigned",
            method: "GET",
            queryParameters: ["contentType": contentType, "filename": filename]
        )

        struct PresignedResponse: Codable {
            let objectKey: String
            let uploadUrl: String    // Upload pre-signed URL
            let assetUrl: String     // Final asset URL
            // Note: legacy `url` field is ignored; decoder will drop unknown keys.
        }

        let presignedResponse: PresignedResponse = try await performRequest(presignedRequest)
        Log.info("Received presigned response for objectKey: \(presignedResponse.objectKey)")

        // Upload to S3 using presigned URL
        guard let s3URL = URL(string: presignedResponse.uploadUrl) else {
            Log.error("Invalid presigned URL received")
            throw APIError.invalidURL
        }

        var s3Request = URLRequest(url: s3URL)
        s3Request.httpMethod = "PUT"
        s3Request.setValue(contentType, forHTTPHeaderField: "Content-Type")
        s3Request.httpBody = data

        Log.info("Uploading \(data.count) bytes to S3")

        let (s3Data, s3Response) = try await URLSession.shared.data(for: s3Request)

        guard let s3HttpResponse = s3Response as? HTTPURLResponse else {
            Log.error("Invalid S3 response type")
            throw APIError.invalidResponse
        }

        Log.info("S3 upload response status: \(s3HttpResponse.statusCode)")

        guard s3HttpResponse.statusCode == 200 else {
            Log.error("S3 upload failed with status: \(s3HttpResponse.statusCode)")
            Log.error("S3 error response: \(String(data: s3Data, encoding: .utf8) ?? "nil")")
            throw APIError.serverError(nil)
        }

        // Require full asset URL. Do not fallback to bare keys.
        guard let assetUrl = URL(string: presignedResponse.assetUrl) else {
            Log.error("Invalid assetUrl in presigned response; refusing to return non-URL")
            throw APIError.invalidResponse
        }

        let assetPath = assetUrl.absoluteString
        Log.info("Successfully uploaded to S3, assetUrl: \(assetPath)")
        return assetPath
    }

    func uploadAttachmentAndExecute(
        data: Data,
        filename: String,
        afterUpload: @escaping (String) async throws -> Void
    ) async throws -> String {
        Log.info("Starting chained upload and execute process for file: \(filename)")

        // Upload the attachment and get the URL
        let uploadedURL = try await uploadAttachment(
            data: data,
            filename: filename,
            contentType: "image/jpeg",
            acl: "public-read"
        )
        Log.info("Upload completed successfully, URL: \(uploadedURL)")

        // Execute the provided closure with the URL
        Log.info("Executing post-upload action with URL: \(uploadedURL)")
        try await afterUpload(uploadedURL)
        Log.info("Post-upload action completed successfully")

        return uploadedURL
    }

    // MARK: - Push Notification Management (JWT-authenticated, inbox-level)

    func subscribeToTopics(deviceId: String, clientId: String, topics: [String]) async throws {
        var request = try authenticatedRequest(for: "v2/notifications/subscribe", method: "POST")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        let topicSubscriptions: [ConvosAPI.TopicSubscription] = topics.map { topic in
            ConvosAPI.TopicSubscription(topic: topic, hmacKeys: [])
        }

        let body = ConvosAPI.SubscribeRequest(
            deviceId: deviceId,
            clientId: clientId,
            topics: topicSubscriptions
        )
        request.httpBody = try JSONEncoder().encode(body)

        let _: EmptyResponse = try await performRequest(request)
    }

    func unsubscribeFromTopics(clientId: String, topics: [String]) async throws {
        var request = try authenticatedRequest(for: "v2/notifications/unsubscribe", method: "POST")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        let body = ConvosAPI.UnsubscribeRequest(clientId: clientId, topics: topics)
        request.httpBody = try JSONEncoder().encode(body)

        let _: EmptyResponse = try await performRequest(request)
    }

    func unregisterInstallation(clientId: String) async throws {
        let path = "v2/notifications/unregister/\(clientId)"
        let request = try authenticatedRequest(for: path, method: "DELETE")
        let _: EmptyResponse = try await performRequest(request)
    }

    // MARK: - Helper Methods

    private func parseErrorMessage(from data: Data) -> String? {
        if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let message = json["message"] as? String {
            return message
        }
        return String(data: data, encoding: .utf8)
    }
}

// MARK: - Error Handling

enum APIError: Error {
    case invalidURL
    case authenticationFailed
    case notAuthenticated
    case badRequest(String?)
    case forbidden
    case notFound
    case noContent
    case invalidResponse
    case invalidRequest
    case serverError(String?)
    case rateLimitExceeded
}

extension APIError: DisplayError {
    var title: String {
        switch self {
        case .invalidURL:
            return "Invalid URL"
        case .authenticationFailed:
            return "Authentication failed"
        case .notAuthenticated:
            return "Not authenticated"
        case .badRequest:
            return "Bad request"
        case .forbidden:
            return "Access denied"
        case .notFound:
            return "Not found"
        case .noContent:
            return "No content"
        case .invalidResponse:
            return "Invalid response"
        case .invalidRequest:
            return "Invalid request"
        case .serverError:
            return "Server error"
        case .rateLimitExceeded:
            return "Too many requests"
        }
    }

    var description: String {
        switch self {
        case .invalidURL:
            return "The URL is not valid."
        case .authenticationFailed:
            return "Failed to authenticate with the server."
        case .notAuthenticated:
            return "Failed to authorize with the server."
        case .badRequest(let message):
            return message ?? "The request was invalid."
        case .forbidden:
            return "You don't have permission to access this."
        case .notFound:
            return "The requested resource was not found."
        case .noContent:
            return "No content was returned."
        case .invalidResponse:
            return "The server returned an invalid response."
        case .invalidRequest:
            return "The request could not be created."
        case .serverError(let message):
            return message ?? "The server encountered an error."
        case .rateLimitExceeded:
            return "Too many requests. Please try again later."
        }
    }
}

extension TimeInterval {
    public static func calculateExponentialBackoff(for retryCount: Int) -> TimeInterval {
        guard retryCount >= 0 else { return 0.0 }
        let baseDelay: TimeInterval = 1.0
        let exponentialDelay = baseDelay * pow(2.0, Double(retryCount))
        let jitter = Double.random(in: 0...0.1) * exponentialDelay
        return min(exponentialDelay + jitter, 30.0) // Cap at 30 seconds
    }
}
