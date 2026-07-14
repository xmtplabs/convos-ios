import ConvosAppData
import ConvosLogging
import Foundation

public protocol ConvosAPIClientFactoryType {
    static func client(environment: AppEnvironment, overrideJWTToken: String?) -> any ConvosAPIClientProtocol
}

public enum ConvosAPIClientFactory: ConvosAPIClientFactoryType {
    public static func client(environment: AppEnvironment, overrideJWTToken: String? = nil) -> any ConvosAPIClientProtocol {
        guard !environment.isTestingEnvironment else {
            return MockAPIClient()
        }
        return ConvosAPIClient(
            environment: environment,
            overrideJWTToken: overrideJWTToken
        )
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

    /// SIWE auth path. Fetches a nonce, has the caller sign an EIP-4361
    /// message, exchanges `(message, signature)` for a JWT containing
    /// `accountId`. Stores the JWT in an address-scoped Keychain slot so
    /// it doesn't collide with the legacy device-only slot.
    ///
    /// The fresh-nonce retry budget (max 1) is internal — callers don't
    /// drive it. If the caller wants more attempts (e.g. on network
    /// flakes), its own outer loop should call this method again; each
    /// call gets a fresh retry budget.
    func authenticateWithSIWE(appCheckToken: String,
                              signing: BackendAuthSigningContext) async throws -> String

    /// Updates (or clears) the SIWE signing context the client uses for
    /// outgoing authenticated requests and for 401 re-auth. Must be
    /// called by the session layer after the on-device identity is
    /// loaded — until then the client falls back to the legacy
    /// device-only auth path.
    func updateSIWESigningContext(_ context: BackendAuthSigningContext?)

    /// Hits `GET /api/v2/account-auth-check` with the supplied JWT
    /// injected directly as `X-Convos-AuthToken` — no Keychain lookup,
    /// no read of the legacy device-id slot, so an NSE token sitting in
    /// `KeychainAccount.jwt(deviceId:)` can't pollute the result. Pass
    /// `nil` to probe the 401 (missing token) path.
    ///
    /// SIWE-bound JWT → 200. Legacy device-only JWT → 403. Missing → 401.
    func accountAuthCheck(jwt: String?) async throws -> ConvosAPI.AuthCheckResponse

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

    func getPresignedUploadURL(
        filename: String,
        contentType: String
    ) async throws -> (uploadURL: String, assetURL: String)

    // Push notifications
    func subscribeToTopics(deviceId: String, clientId: String, topics: [String]) async throws
    func unsubscribeFromTopics(clientId: String, topics: [String]) async throws
    func unregisterInstallation(clientId: String) async throws

    // Asset renewal
    func renewAssetsBatch(assetKeys: [String]) async throws -> AssetRenewalResult

    // Agents
    /// Exactly one of `slug` (invite flow) and `conversationId` (direct-add).
    /// In direct-add mode the backend provisions the agent and returns its
    /// `inboxId`; the caller adds that inbox to the declared group with
    /// addMembers and the runtime attaches when it observes the resulting
    /// group welcome — no further calls.
    /// `joinRequest` is the wire body (see `ConvosAPI.AgentJoinRequest` for
    /// per-field semantics, including the retry-stable `idempotencyKey`).
    /// `forceErrorCode` is a test/debug knob riding an HTTP header, which is
    /// why it is a separate parameter and not part of the body type.
    func requestAgentJoin(
        _ joinRequest: ConvosAPI.AgentJoinRequest,
        forceErrorCode: Int?
    ) async throws -> ConvosAPI.AgentJoinResponse

    /// Polls a dispatched agent's provisioning status. Direct-add callers
    /// use it to obtain `inboxId` when the join response didn't carry one.
    /// `variantId` (dev-only) is appended as a `?variantId=` query param; it is
    /// load-bearing for variant-built agents because the backend only routes the
    /// poll to the variant's ephemeral worker when present, so omitting it makes
    /// the poll hit the default worker, which has no record of the instance.
    func getAgentJoinStatus(instanceId: String, variantId: String?) async throws -> ConvosAPI.AgentJoinStatusResponse

    // Agent templates
    /// Public detail fetch for a published agent template, keyed by its
    /// template id (UUID) or hashed url slug (e.g. `gandalf.felpl`). Backs the
    /// agent-share card/chip resolver. Authenticated: the backend serves
    /// published templates to anonymous callers, but drafts are only returned to authenticated owners.
    func getAgentTemplate(idOrUrlSlug: String) async throws -> ConvosAPI.AgentTemplate

    /// Lists featured (curated) published agent templates, cursor-paginated.
    /// Backs the contacts picker's "Suggested agents" section. Pass `nil`
    /// `cursor` for the first page, then thread `AgentTemplatesPage.nextCursor`
    /// back for each following page until `hasMore` is `false`.
    /// Unauthenticated: featured templates are published, so the backend
    /// serves them to anonymous callers (mirrors `getAgentTemplate`).
    func getFeaturedAgentTemplates(limit: Int, cursor: String?) async throws -> ConvosAPI.AgentTemplatesPage

    /// Lists curated agent prompt hints (`GET /v2/agent-prompt-hints`) -- a flat
    /// array of short prompt strings used to seed the agent builder's composer
    /// via the dice control. Unauthenticated: the hints are public, so
    /// `request(for:)` builds a bare GET (no auth header), mirroring
    /// `getFeaturedAgentTemplates`.
    func getAgentPromptHints() async throws -> [String]

    /// Lists registered dev-only agent variants (`GET /v2/agent-variants`).
    /// Authenticated (user JWT) and served only by the dev backend -- elsewhere
    /// it returns an empty list. Backs the Debug-menu variant picker.
    func getAgentVariants() async throws -> [ConvosAPI.AgentVariant]

    /// Submits an async template generation (`POST /v2/agent-templates/generations`).
    /// Returns 202 with `status: pending` by default; the caller polls
    /// `getAgentTemplateGeneration` for the terminal state. `idempotencyKey`
    /// must be a UUID and is reused across retries of the same submit.
    func createAgentTemplateGeneration(
        inputs: ConvosAPI.AgentTemplateGenerationRequest.Inputs,
        source: String,
        clientDeviceId: String?,
        idempotencyKey: String,
        connections: [String],
        variantId: String?
    ) async throws -> ConvosAPI.AgentTemplateGenerationResponse

    /// Polls a generation's status (`GET /v2/agent-templates/generations/:id`).
    /// The generation id is the capability, so no extra auth is required.
    func getAgentTemplateGeneration(
        generationId: String
    ) async throws -> ConvosAPI.AgentTemplateGenerationResponse

    /// Mints a presigned PUT for one generation attachment.
    /// `GET /v2/agent-templates/attachments/presigned?contentType=…&contentLength=…`
    /// returns an opaque `objectKey` (echo it back in `inputs.attachments[]`) and
    /// the presigned S3 `uploadURL`. Private bucket — no public asset URL is
    /// minted; `contentType` must be in the backend allowlist and `contentLength`
    /// (the exact byte count of the upload) is baked into the presigned URL, so
    /// the subsequent `PUT` body must match it.
    func getAgentTemplateAttachmentPresignedURL(
        contentType: String,
        contentLength: Int
    ) async throws -> (objectKey: String, uploadURL: String)

    /// Uploads the raw (unencrypted) bytes of a generation attachment to the
    /// presigned `uploadURL` with the given `Content-Type`. The backend reads
    /// the bytes itself, so nothing is encrypted and no XMTP content is built.
    func uploadAgentTemplateAttachment(
        data: Data,
        contentType: String,
        to uploadURL: String
    ) async throws

    // Connections
    func initiateCloudConnection(serviceId: String, redirectUri: String) async throws -> CloudConnectionsAPI.InitiateResponse
    func completeCloudConnection(connectionRequestId: String) async throws -> CloudConnectionsAPI.CompleteResponse
    func listCloudConnections() async throws -> [CloudConnectionsAPI.ConnectionResponse]
    func revokeCloudConnection(connectionId: String) async throws

    /// Fetches the backend-owned connections-picker catalog: one entry per
    /// service, each with its permission bundles. The response is served with
    /// `Cache-Control: private, max-age=300`; callers should go through
    /// `ConnectionServicesStore`, which honors that TTL client-side, instead
    /// of hitting this directly.
    func getConnectionServices() async throws -> CloudConnectionsAPI.ServicesResponse

    /// Pushes one per-agent consent record to the backend grant store. The
    /// backend uses these records to authorize agent tool execution; without
    /// the push the agent gets 403. Re-posting the same (owner, grantee,
    /// conversation, toolkit) tuple upserts (also un-revokes) and returns the
    /// same id.
    ///
    /// `bundleIds` lists the permission-bundle ids the user toggled on
    /// (e.g. "calendar.events"); the backend resolves them to Composio
    /// actions at exec time. `nil` omits the field — for toolkits outside
    /// the catalog the backend treats that as the legacy whole-toolkit
    /// grant. `serviceVersion` is the catalog version the device granted
    /// against (audit/stale telemetry). An unknown bundle id surfaces as
    /// `CloudConnectionsAPI.GrantError.unknownBundle`.
    func createConnectionGrant(
        ownerInboxId: String,
        granteeInboxId: String,
        conversationId: String,
        toolkit: String,
        bundleIds: [String]?,
        serviceVersion: Int?
    ) async throws -> CloudConnectionsAPI.CreateGrantResponse

    /// Revokes a backend consent record previously created by
    /// `createConnectionGrant`. The backend returns 404 for unknown or
    /// not-owned ids; that surfaces here as an error the caller can log.
    func revokeConnectionGrant(id: String) async throws

    /// Revokes the caller's own grants by natural key. Reliable even when no
    /// backend grant id was stored locally (the by-id path can't run then).
    /// `toolkit` alone revokes every grant for that connection (full
    /// disconnect); adding `conversationId` scopes to one conversation; adding
    /// `granteeInboxId` scopes to a single agent. Returns the number revoked.
    @discardableResult
    func revokeConnectionGrantByNaturalKey(
        toolkit: String,
        conversationId: String?,
        granteeInboxId: String?
    ) async throws -> Int

    // IAP credits + subscriptions
    func getCreditBalance() async throws -> CreditBalance
    func getSubscription() async throws -> UserSubscription?
    func verifySubscription(jwsRepresentation: String) async throws -> UserSubscription
}

extension ConvosAPIClientProtocol {
    func requestAgentJoin(slug: String) async throws -> ConvosAPI.AgentJoinResponse {
        try await requestAgentJoin(ConvosAPI.AgentJoinRequest(slug: slug), forceErrorCode: nil)
    }

    func requestAgentJoin(
        slug: String,
        options: ConvosAPI.AgentJoinOptions?
    ) async throws -> ConvosAPI.AgentJoinResponse {
        try await requestAgentJoin(ConvosAPI.AgentJoinRequest(slug: slug, options: options), forceErrorCode: nil)
    }

    func requestAgentJoin(
        slug: String,
        templateId: String?
    ) async throws -> ConvosAPI.AgentJoinResponse {
        try await requestAgentJoin(ConvosAPI.AgentJoinRequest(slug: slug, templateId: templateId), forceErrorCode: nil)
    }

    /// Default so bespoke test doubles that don't exercise the builder don't
    /// have to stub these. The real `ConvosAPIClient` and `MockAPIClient`
    /// override both.
    func createAgentTemplateGeneration(
        inputs: ConvosAPI.AgentTemplateGenerationRequest.Inputs,
        source: String,
        clientDeviceId: String?,
        idempotencyKey: String,
        connections: [String],
        variantId: String?
    ) async throws -> ConvosAPI.AgentTemplateGenerationResponse {
        throw APIError.invalidRequest
    }

    func getAgentTemplateGeneration(
        generationId: String
    ) async throws -> ConvosAPI.AgentTemplateGenerationResponse {
        throw APIError.invalidRequest
    }

    func getAgentTemplateAttachmentPresignedURL(
        contentType: String,
        contentLength: Int
    ) async throws -> (objectKey: String, uploadURL: String) {
        throw APIError.invalidRequest
    }

    func uploadAgentTemplateAttachment(
        data: Data,
        contentType: String,
        to uploadURL: String
    ) async throws {
        throw APIError.invalidRequest
    }
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
/// Thread-safe slot for the active SIWE signing context. ConvosAPIClient
/// is otherwise immutable + Sendable; this is the one piece of mutable
/// state we need so the authenticated request path and the 401 refresh
/// path can pick up the same context the session-level auth call used,
/// without exposing libxmtp / KeychainIdentity through the protocol.
///
/// Shared across all `ConvosAPIClient` instances via `.shared`. Multiple
/// services in the app (`SessionManager` and any non-session services
/// that construct their own `ConvosAPIClient` via the factory — e.g.
/// `BackendCreditsService`, `StoreKitSubscriptionService` on the IAP
/// credits branch) each get their own client. Per-instance slots meant
/// only the SessionManager's client saw the registered context, and the
/// others silently fell back to legacy device-only auth on 401 refresh,
/// minting JWTs without `accountId` and 403-ing every `requireAccount`-
/// gated call. The static singleton keeps the registered context visible
/// to all clients in the process.
final class LockedSigningContext: @unchecked Sendable {
    static let shared: LockedSigningContext = LockedSigningContext()

    private let lock: NSLock = NSLock()
    private var value: BackendAuthSigningContext?

    func set(_ ctx: BackendAuthSigningContext?) {
        lock.lock(); defer { lock.unlock() }
        value = ctx
    }

    func get() -> BackendAuthSigningContext? {
        lock.lock(); defer { lock.unlock() }
        return value
    }
}

final class ConvosAPIClient: ConvosAPIClientProtocol, Sendable {
    let baseURL: URL
    private let session: URLSession
    let environment: AppEnvironment
    let keychainService: any KeychainServiceProtocol = KeychainService()
    private let overrideJWTToken: String?  // Immutable JWT override from APNS payload
    let maxRetryCount: Int = 3
    let siweSigningContext: LockedSigningContext = .shared

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

    func updateSIWESigningContext(_ context: BackendAuthSigningContext?) {
        siweSigningContext.set(context)
    }

    private func reAuthenticate() async throws -> String {
        let firebaseAppCheckToken = try await FirebaseHelperCore.getAppCheckToken()
        // If a SIWE signing context is configured for this session,
        // re-auth must reissue a SIWE-bound JWT. Falling back to
        // legacy `{ deviceId }` here would silently downgrade the
        // session to a token missing `accountId`, breaking any
        // route gated by `requireAccount`.
        if let context = siweSigningContext.get() {
            return try await authenticateWithSIWE(
                appCheckToken: firebaseAppCheckToken,
                signing: context
            )
        }
        // 401-refresh hit before the session registered a SIWE
        // signing context. The token we're about to mint will not
        // carry `accountId`, so any subsequent /account-auth-check or
        // requireAccount-gated call will 403. Logged here so iOS
        // logs alone can tell us a refresh raced session bootstrap.
        Log.warning("reAuthenticate: no SIWE signing context; falling back to legacy device-only auth")
        return try await authenticate(
            appCheckToken: firebaseAppCheckToken,
            retryCount: 0
        )
    }

    func isJWTValid(_ token: String) -> Bool {
        // JWT format: header.payload.signature
        let parts = token.split(separator: ".")
        guard parts.count == 3 else { return false }

        let payload = String(parts[1])
        guard let payloadData = try? payload.base64URLDecoded(),
              let json = try? JSONSerialization.jsonObject(with: payloadData) as? [String: Any],
              let exp = json["exp"] as? TimeInterval else {
            return false
        }
        // Valid if expiration is more than 60 seconds from now
        return Date(timeIntervalSince1970: exp) > Date().addingTimeInterval(60)
    }

    // MARK: - Authentication

    /// Authenticates with the backend to obtain a JWT token
    /// - Parameters:
    ///   - appCheckToken: Firebase AppCheck token for authentication
    ///   - retryCount: Number of retry attempts (for rate limiting)
    /// - Returns: JWT token string
    func authenticate(appCheckToken: String,
                      retryCount: Int = 0) async throws -> String {
        let deviceId = DeviceInfo.deviceIdentifier

        // Check for existing valid JWT token first
        if let existingToken = try? keychainService.retrieveString(
            account: KeychainAccount.jwt(deviceId: deviceId)
        ), !existingToken.isEmpty,
           isJWTValid(existingToken) {
            Log.info("Using existing JWT token from keychain")
            return existingToken
        }

        // Minting a non-SIWE token. Surfaces on the backend as
        // `hasSiwe: false`. Expected only on first-launch (before an
        // XMTP identity is provisioned) or as a 401-refresh fallback
        // when the SIWE signing context hasn't been registered yet —
        // never in steady state. If you see this warning while
        // signed-in, an earlier call path skipped SIWE.
        Log.warning("Legacy device-only auth: minting JWT without accountId (hasSiwe: false)")

        // Token missing or expired - fetch new one
        let url = baseURL.appendingPathComponent("v2/auth/token")
        var request = URLRequest(url: url)
        request.httpMethod = "POST"

        request.setValue(appCheckToken, forHTTPHeaderField: "X-Firebase-AppCheck")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        struct AuthRequest: Encodable {
            let deviceId: String
        }

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

        // JWT selection precedence:
        //   1. overrideJWTToken (APNS-injected, NSE flow)
        //   2. SIWE-bound JWT in the address-scoped slot, when a signing
        //      context is configured for this session
        //   3. Legacy device-only JWT slot (only reachable when no
        //      signing context is set yet — e.g. early boot before the
        //      XMTP identity is loaded)
        if let overrideJWT = overrideJWTToken {
            Log.debug("Using override JWT token from notification payload")
            request.setValue(overrideJWT, forHTTPHeaderField: "X-Convos-AuthToken")
        } else if let jwt = retrieveCurrentJWT() {
            request.setValue(jwt, forHTTPHeaderField: "X-Convos-AuthToken")
        } else {
            Log.debug("No JWT token found - request will trigger re-authentication")
        }

        return request
    }

    /// Returns the JWT we'd attach to a fresh authenticated request,
    /// honoring the SIWE slot when a signing context is set. Used by
    /// `authenticatedRequest` and by the SIWE accountAuthCheck path.
    func retrieveCurrentJWT() -> String? {
        let deviceId = DeviceInfo.deviceIdentifier

        if let context = siweSigningContext.get() {
            let siweSlot = KeychainAccount.siweJwt(deviceId: deviceId, address: context.address)
            do {
                if let siweJWT = try keychainService.retrieveString(account: siweSlot),
                   !siweJWT.isEmpty {
                    Log.debug("Using SIWE JWT from address-scoped keychain slot")
                    return siweJWT
                }
            } catch {
                Log.warning("Failed to retrieve SIWE JWT: \(error.localizedDescription)")
            }
        }

        do {
            if let legacy = try keychainService.retrieveString(account: KeychainAccount.jwt(deviceId: deviceId)),
               !legacy.isEmpty {
                Log.debug("Using legacy JWT from keychain (no SIWE context configured)")
                return legacy
            }
        } catch {
            Log.warning("Failed to retrieve legacy JWT: \(error.localizedDescription)")
        }

        return nil
    }

    private func performRequest<T: Decodable>(_ request: URLRequest) async throws -> T {
        let (data, httpResponse) = try await performAuthenticatedRequest(request)

        Log.info("\(request.url?.path(percentEncoded: false) ?? "nil") received response: \(data.prettyPrintedJSONString ?? "nil data")")

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
            if T.self == EmptyResponse.self,
               let emptyResponse = EmptyResponse() as? T {
                return emptyResponse
            } else if let emptyDict = [:] as? T {
                return emptyDict
            } else if let emptyArray = [] as? T {
                return emptyArray
            } else {
                throw APIError.noContent
            }
        case 400:
            throw APIError.badRequest(parseErrorMessage(from: data))
        case 403:
            throw APIError.forbidden
        case 404:
            throw APIError.notFound
        default:
            // 409 (subscription_account_mismatch) falls through deliberately.
            // The backend still returns it (PR #215 strict-ownership invariant),
            // but iOS treats it as a generic retryable server fault instead
            // of a typed dead-end — purchase + restore flows already surface
            // .serverError with a "try again" affordance, and refresh logic
            // (foreground + view-appear) will reconcile any transient state.
            throw APIError.serverError(parseErrorMessage(from: data))
        }
    }

    private func performAuthenticatedRequest(
        _ request: URLRequest,
        retryCount: Int = 0
    ) async throws -> (Data, HTTPURLResponse) {
        let (data, response) = try await session.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw APIError.invalidResponse
        }

        guard httpResponse.statusCode == 401 else {
            return (data, httpResponse)
        }

        guard overrideJWTToken == nil else {
            Log.error("Authentication failed in JWT override mode - cannot re-authenticate without AppCheck")
            throw APIError.notAuthenticated
        }

        guard retryCount < maxRetryCount else {
            Log.error("Max retry count (\(maxRetryCount)) exceeded for request")
            throw APIError.notAuthenticated
        }

        Log.info("Attempting re-authentication (attempt \(retryCount + 1) of \(maxRetryCount))")
        let freshJWT = try await reAuthenticate()
        guard !freshJWT.isEmpty else {
            throw APIError.notAuthenticated
        }

        var newRequest = request
        newRequest.setValue(freshJWT, forHTTPHeaderField: "X-Convos-AuthToken")
        return try await performAuthenticatedRequest(newRequest, retryCount: retryCount + 1)
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

    func getPresignedUploadURL(
        filename: String,
        contentType: String
    ) async throws -> (uploadURL: String, assetURL: String) {
        Log.info("Getting presigned URL for file: \(filename)")

        let presignedRequest = try authenticatedRequest(
            for: "v2/attachments/presigned",
            method: "GET",
            queryParameters: ["contentType": contentType, "filename": filename]
        )

        struct PresignedResponse: Codable {
            let objectKey: String
            let uploadUrl: String
            let assetUrl: String
        }

        let response: PresignedResponse = try await performRequest(presignedRequest)
        Log.info("Received presigned URL for objectKey: \(response.objectKey)")

        return (uploadURL: response.uploadUrl, assetURL: response.assetUrl)
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

    // MARK: - Asset Renewal

    func renewAssetsBatch(assetKeys: [String]) async throws -> AssetRenewalResult {
        var request = try authenticatedRequest(for: "v2/assets/renew-batch", method: "POST")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        let body = ConvosAPI.BatchRenewRequest(assetKeys: assetKeys)
        request.httpBody = try JSONEncoder().encode(body)

        let response: ConvosAPI.BatchRenewResponse = try await performRequest(request)

        let expiredKeys = response.results
            .filter { !$0.success && $0.error == "not_found" }
            .map { $0.key }

        return AssetRenewalResult(
            renewed: response.renewed,
            failed: response.failed,
            expiredKeys: expiredKeys
        )
    }

    // MARK: - Agents

    // `requestAgentJoin` lives in the agent-template extension below to keep
    // the class body under the type-length budget.

    func getAgentJoinStatus(instanceId: String, variantId: String?) async throws -> ConvosAPI.AgentJoinStatusResponse {
        let encoded = instanceId.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? instanceId
        // `variantId` is load-bearing here: the backend only routes the poll to
        // the variant's ephemeral worker when it is present, so a variant-built
        // agent whose poll omits it stalls against the default worker.
        let queryParameters = Self.agentJoinStatusQueryParameters(variantId: prodSafeVariantId(variantId))
        var request = try authenticatedRequest(for: "v2/agents/join/\(encoded)", method: "GET", queryParameters: queryParameters)
        // Bound a single poll: without this a hung GET stalls the caller's
        // registration loop indefinitely, since the loop's own deadline is
        // only checked between iterations and can't interrupt an in-flight
        // request. Kept well under the loop's overall deadline so a stuck
        // request fails fast and the next iteration's deadline check fires.
        request.timeoutInterval = 10
        return try await performRequest(request)
    }

    // MARK: - Agent templates

    func getAgentTemplate(idOrUrlSlug: String) async throws -> ConvosAPI.AgentTemplate {
        // Authenticated GET. Published templates are visible to anyone, but a
        // `draft` template (every builder-flow template lands as a draft) is
        // only returned to its owner -- the backend matches `res.locals.accountId`
        // against the template's owner, so an anonymous request 404s on a draft
        // the caller actually owns. Attaching the JWT lets the owner resolve
        // their own drafts (e.g. the `AgentTemplateCacheCoordinator` populating
        // the canonical identity cache for agents the user just built); it is a
        // no-op for published templates fetched via share links.
        let encoded = idOrUrlSlug.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? idOrUrlSlug
        let request = try authenticatedRequest(for: "v2/agent-templates/\(encoded)")
        return try await performRequest(request)
    }

    func getFeaturedAgentTemplates(limit: Int, cursor: String?) async throws -> ConvosAPI.AgentTemplatesPage {
        // Public, unauthenticated GET -- featured templates are published, so
        // the list endpoint serves them to anonymous callers. `request(for:)`
        // builds a bare GET (no auth header).
        var queryParameters: [String: String] = [
            "featured": "true",
            "limit": String(limit),
        ]
        if let cursor, !cursor.isEmpty {
            queryParameters["cursor"] = cursor
        }
        let request = try request(for: "v2/agent-templates", queryParameters: queryParameters)
        return try await performRequest(request)
    }

    func getAgentPromptHints() async throws -> [String] {
        // Public, unauthenticated GET -- the curated hints are not user-scoped,
        // so `request(for:)` builds a bare GET (no auth header).
        let request = try request(for: "v2/agent-prompt-hints")
        let response: ConvosAPI.AgentPromptHintsResponse = try await performRequest(request)
        return response.hints
    }

    func getAgentVariants() async throws -> [ConvosAPI.AgentVariant] {
        // Authenticated GET -- the registry is dev-gated and sends the user JWT.
        // The response is enveloped (`{ data: [...] }`); on the prod backend the
        // route serves an empty list.
        let request = try authenticatedRequest(for: "v2/agent-variants")
        let response: ConvosAPI.AgentVariantsResponse = try await performRequest(request)
        if response.data.isEmpty {
            // A throw would mean a transport/auth failure; an empty list is the
            // route's intended prod response (or no open variants in dev). Log so
            // the two are distinguishable when the picker shows nothing.
            Log.info("getAgentVariants: registry returned an empty list")
        }
        return response.data
    }

    func createAgentTemplateGeneration(
        inputs: ConvosAPI.AgentTemplateGenerationRequest.Inputs,
        source: String,
        clientDeviceId: String?,
        idempotencyKey: String,
        connections: [String],
        variantId: String?
    ) async throws -> ConvosAPI.AgentTemplateGenerationResponse {
        var request = try authenticatedRequest(for: "v2/agent-templates/generations", method: "POST")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(idempotencyKey, forHTTPHeaderField: "Idempotency-Key")
        let body = try JSONEncoder().encode(
            ConvosAPI.AgentTemplateGenerationRequest(
                source: source,
                inputs: inputs,
                connections: connections.isEmpty ? nil : connections,
                clientDeviceId: clientDeviceId,
                publishStatus: "unlisted",
                variantId: prodSafeVariantId(variantId)
            )
        )
        request.httpBody = body
        let (data, httpResponse) = try await performAuthenticatedRequest(request)
        return try decodeGenerationResponse(data: data, httpResponse: httpResponse)
    }

    func getAgentTemplateGeneration(
        generationId: String
    ) async throws -> ConvosAPI.AgentTemplateGenerationResponse {
        let encoded = generationId.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? generationId
        let request = try authenticatedRequest(for: "v2/agent-templates/generations/\(encoded)")
        let (data, httpResponse) = try await performAuthenticatedRequest(request)
        return try decodeGenerationResponse(data: data, httpResponse: httpResponse)
    }

    // MARK: - Connections

    func initiateCloudConnection(serviceId: String, redirectUri: String) async throws -> CloudConnectionsAPI.InitiateResponse {
        var request = try authenticatedRequest(for: "v2/connections/initiate", method: "POST")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        struct InitiateBody: Codable {
            let serviceId: String
            let redirectUri: String
        }
        request.httpBody = try JSONEncoder().encode(
            InitiateBody(serviceId: serviceId, redirectUri: redirectUri)
        )

        return try await performRequest(request)
    }

    func completeCloudConnection(connectionRequestId: String) async throws -> CloudConnectionsAPI.CompleteResponse {
        var request = try authenticatedRequest(for: "v2/connections/complete", method: "POST")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        struct CompleteBody: Codable {
            let connectionRequestId: String
        }
        request.httpBody = try JSONEncoder().encode(CompleteBody(connectionRequestId: connectionRequestId))

        return try await performRequest(request)
    }

    func listCloudConnections() async throws -> [CloudConnectionsAPI.ConnectionResponse] {
        let request = try authenticatedRequest(for: "v2/connections", method: "GET")
        let response: CloudConnectionsAPI.ListResponse = try await performRequest(request)
        return response.connections
    }

    func revokeCloudConnection(connectionId: String) async throws {
        let request = try authenticatedRequest(for: "v2/connections/\(connectionId)", method: "DELETE")
        let _: EmptyResponse = try await performRequest(request)
    }

    func getConnectionServices() async throws -> CloudConnectionsAPI.ServicesResponse {
        let request = try authenticatedRequest(for: "v2/connections/services", method: "GET")
        return try await performRequest(request)
    }

    func createConnectionGrant(
        ownerInboxId: String,
        granteeInboxId: String,
        conversationId: String,
        toolkit: String,
        bundleIds: [String]?,
        serviceVersion: Int?
    ) async throws -> CloudConnectionsAPI.CreateGrantResponse {
        var request = try authenticatedRequest(for: "v2/connections/grants", method: "POST")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        struct GrantBody: Codable {
            let ownerInboxId: String
            let granteeInboxId: String
            let conversationId: String
            let toolkit: String
            let bundleIds: [String]?
            let serviceVersion: Int?
        }
        request.httpBody = try JSONEncoder().encode(
            GrantBody(
                ownerInboxId: ownerInboxId,
                granteeInboxId: granteeInboxId,
                conversationId: conversationId,
                toolkit: toolkit,
                bundleIds: bundleIds,
                serviceVersion: serviceVersion
            )
        )

        do {
            return try await performRequest(request)
        } catch let APIError.badRequest(message) {
            // The unknown-bundle 400 body is `{"code": "unknown_bundle",
            // "bundleId": "<id>"}` — no `message`/`error` key, so
            // `parseErrorMessage` passes the raw JSON body through. Decode it
            // here so callers get a typed staleness signal they can retry on.
            struct GrantErrorBody: Decodable {
                let code: String
                let bundleId: String?
            }
            if let message,
               let data = message.data(using: .utf8),
               let body = try? JSONDecoder().decode(GrantErrorBody.self, from: data),
               body.code == "unknown_bundle" {
                throw CloudConnectionsAPI.GrantError.unknownBundle(bundleId: body.bundleId)
            }
            throw APIError.badRequest(message)
        }
    }

    func revokeConnectionGrant(id: String) async throws {
        let request = try authenticatedRequest(for: "v2/connections/grants/\(id)", method: "DELETE")
        let _: EmptyResponse = try await performRequest(request)
    }

    @discardableResult
    func revokeConnectionGrantByNaturalKey(
        toolkit: String,
        conversationId: String?,
        granteeInboxId: String?
    ) async throws -> Int {
        var request = try authenticatedRequest(for: "v2/connections/grants/revoke", method: "POST")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        struct RevokeBody: Codable {
            let toolkit: String
            let conversationId: String?
            let granteeInboxId: String?
        }
        request.httpBody = try JSONEncoder().encode(
            RevokeBody(
                toolkit: toolkit,
                conversationId: conversationId,
                granteeInboxId: granteeInboxId
            )
        )

        let response: CloudConnectionsAPI.RevokeGrantResponse = try await performRequest(request)
        return response.revoked
    }

    // MARK: - IAP Credits + Subscriptions

    func getCreditBalance() async throws -> CreditBalance {
        let request = try authenticatedRequest(for: "v2/accounts/me/credits", method: "GET")
        return try await performRequest(request)
    }

    func getSubscription() async throws -> UserSubscription? {
        let request = try authenticatedRequest(for: "v2/accounts/me/subscription", method: "GET")
        do {
            let sub: UserSubscription = try await performRequest(request)
            return sub
        } catch APIError.noContent {
            return nil
        }
    }

    func verifySubscription(jwsRepresentation: String) async throws -> UserSubscription {
        var request = try authenticatedRequest(for: "v2/accounts/me/subscription/verify", method: "POST")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let body = ConvosAPI.VerifySubscriptionRequest(jwsRepresentation: jwsRepresentation)
        request.httpBody = try JSONEncoder().encode(body)
        let response: ConvosAPI.VerifySubscriptionResponse = try await performRequest(request)
        return response.subscription
    }

    // MARK: - Helper Methods

    func parseErrorMessage(from data: Data) -> String? {
        if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            if let message = json["message"] as? String {
                return message
            }
            if let error = json["error"] as? String {
                return error
            }
        }
        return String(data: data, encoding: .utf8)
    }
}

// MARK: - Agent join + template generation (split out to keep the class body length in check)

extension ConvosAPIClient {
    /// Defense-in-depth: drop any dev variant slug in production. The invariant
    /// is enforced at the source (FeatureFlags hard-locks the selection to nil in
    /// prod), so nothing should reach here; this keeps the client honest even if
    /// a future caller isn't gated.
    func prodSafeVariantId(_ slug: String?) -> String? {
        environment.isProduction ? nil : slug
    }

    /// Query parameters for the join-status poll. The dev `variantId` is the
    /// load-bearing routing key; omitted entirely when nil so a default poll
    /// stays byte-identical to the pre-variant shape.
    static func agentJoinStatusQueryParameters(variantId: String?) -> [String: String]? {
        variantId.map { ["variantId": $0] }
    }

    func requestAgentJoin(
        _ joinRequest: ConvosAPI.AgentJoinRequest,
        forceErrorCode: Int? = nil
    ) async throws -> ConvosAPI.AgentJoinResponse {
        var request = try authenticatedRequest(for: "v2/agents/join", method: "POST")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        // Backend pool timeout is 30s; give 5s buffer so backend returns a proper 504 before iOS times out
        request.timeoutInterval = 35

        if let forceErrorCode {
            request.setValue("\(forceErrorCode)", forHTTPHeaderField: "X-Force-Error")
        }

        // Prod backstop: strip a leaked dev variant slug from the join options
        // before the body is encoded.
        let safeOptions = joinRequest.options.map {
            ConvosAPI.AgentJoinOptions(onboarding: $0.onboarding, variantId: prodSafeVariantId($0.variantId))
        }
        request.httpBody = try JSONEncoder().encode(
            ConvosAPI.AgentJoinRequest(
                slug: joinRequest.slug,
                conversationId: joinRequest.conversationId,
                templateId: joinRequest.templateId,
                idempotencyKey: joinRequest.idempotencyKey,
                options: safeOptions,
                timezone: joinRequest.timezone
            )
        )

        let (data, httpResponse) = try await performAuthenticatedRequest(request)

        // "join key <k>" / key annotations appear only on keyed joins so
        // keyless joins keep their original log shape.
        let keySuffix = joinRequest.idempotencyKey.map { " idempotencyKey=\($0.rawValue)" } ?? ""
        if !(200...299).contains(httpResponse.statusCode) {
            Log.error("agents/join failed [\(httpResponse.statusCode)]\(keySuffix): \(String(data: data, encoding: .utf8) ?? "nil data")")
        }
        switch httpResponse.statusCode {
        case 200...299:
            let decoder = JSONDecoder()
            let response = try decoder.decode(ConvosAPI.AgentJoinResponse.self, from: data)
            // When a key was sent, the returned instanceId should equal it (the
            // key is the workflow instance id); a match on a retry is the
            // client-visible proof the server adopted rather than re-provisioned.
            let matchSuffix = joinRequest.idempotencyKey.map { " idempotencyKey=\($0.rawValue) instanceIdMatchesKey=\(response.instanceId == $0.rawValue)" } ?? ""
            Log.info("agents/join succeeded: instanceId=\(response.instanceId ?? "nil")\(matchSuffix) joined=\(response.joined) inboxIdPresent=\(response.inboxId != nil)")
            return response
        case 502:
            throw APIError.agentProvisionFailed
        case 503:
            throw APIError.noAgentsAvailable
        case 504:
            throw APIError.agentPoolTimeout
        case 400:
            throw APIError.badRequest(parseErrorMessage(from: data))
        case 403:
            throw APIError.forbidden
        case 404:
            throw APIError.notFound
        case 410:
            // Template resolved but is archived - the backend won't
            // provision an instance from it.
            throw APIError.templateArchived
        default:
            throw APIError.serverError(parseErrorMessage(from: data))
        }
    }

    func getAgentTemplateAttachmentPresignedURL(
        contentType: String,
        contentLength: Int
    ) async throws -> (objectKey: String, uploadURL: String) {
        let request = try authenticatedRequest(
            for: "v2/agent-templates/attachments/presigned",
            method: "GET",
            queryParameters: ["contentType": contentType, "contentLength": String(contentLength)]
        )
        let (data, httpResponse) = try await performAuthenticatedRequest(request)
        guard (200...299).contains(httpResponse.statusCode) else {
            throw APIError.serverError(parseErrorMessage(from: data))
        }
        struct PresignedResponse: Codable {
            let objectKey: String
            let uploadUrl: String
        }
        let decoded = try JSONDecoder().decode(PresignedResponse.self, from: data)
        return (objectKey: decoded.objectKey, uploadURL: decoded.uploadUrl)
    }

    func uploadAgentTemplateAttachment(
        data: Data,
        contentType: String,
        to uploadURL: String
    ) async throws {
        guard let url = URL(string: uploadURL) else {
            throw APIError.invalidURL
        }
        var request = URLRequest(url: url)
        request.httpMethod = "PUT"
        request.setValue(contentType, forHTTPHeaderField: "Content-Type")
        request.httpBody = data
        let (respData, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw APIError.invalidResponse
        }
        guard (200...299).contains(http.statusCode) else {
            Log.error("AgentAttachment PUT failed [\(http.statusCode)]: \(String(data: respData, encoding: .utf8) ?? "nil")")
            throw APIError.serverError(nil)
        }
    }

    func decodeGenerationResponse(
        data: Data,
        httpResponse: HTTPURLResponse
    ) throws -> ConvosAPI.AgentTemplateGenerationResponse {
        if !(200...299).contains(httpResponse.statusCode) {
            let path: String = httpResponse.url?.path(percentEncoded: false) ?? "agent-template generation"
            Log.error("\(path) failed [\(httpResponse.statusCode)]: \(String(data: data, encoding: .utf8) ?? "nil data")")
        }
        switch httpResponse.statusCode {
        case 200...299:
            return try JSONDecoder().decode(ConvosAPI.AgentTemplateGenerationResponse.self, from: data)
        case 400:
            throw AgentGenerationError.badRequest(parseErrorMessage(from: data))
        case 401, 403:
            // Auth refresh already ran inside performAuthenticatedRequest, so a
            // surfaced 401/403 won't heal on a plain retry - treat as terminal
            // rather than looping through the retryable `.server` path.
            throw AgentGenerationError.badRequest(parseErrorMessage(from: data) ?? "Not authorized")
        case 404:
            throw AgentGenerationError.notFound
        case 409:
            throw AgentGenerationError.conflict
        case 413:
            throw AgentGenerationError.payloadTooLarge
        case 422:
            throw AgentGenerationError.moderationBlocked(parseErrorMessage(from: data))
        default:
            throw AgentGenerationError.server(parseErrorMessage(from: data))
        }
    }
}

// MARK: - Error Handling

public enum APIError: Error {
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
    case noAgentsAvailable
    case agentPoolTimeout
    case agentProvisionFailed
    case templateArchived
}

extension APIError: DisplayError {
    public var title: String {
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
        case .noAgentsAvailable:
            return "No agents available"
        case .agentPoolTimeout:
            return "Agent timed out"
        case .agentProvisionFailed:
            return "Couldn't add agent"
        case .templateArchived:
            return "Agent unavailable"
        }
    }

    public var description: String {
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
        case .noAgentsAvailable:
            return "No agents are available right now. Please try again later."
        case .agentPoolTimeout:
            return "Agent setup took too long. Please try again."
        case .agentProvisionFailed:
            return "Something went wrong while adding an agent. Please try again."
        case .templateArchived:
            return "This agent has been archived and can't be added to a conversation."
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
