import ConvosLogging
import Foundation

extension ConvosAPIClient {
    // MARK: - Public SIWE entry points

    /// Max number of fresh-nonce retries on 401 from `/auth/token`. The
    /// backend burns the nonce on every attempt regardless of signature
    /// validity, so a retry must restart from `/auth/nonce`. One retry
    /// covers the typical race (nonce TTL expired between fetch and
    /// exchange) without masking a real signing bug.
    static let maxSIWENonceRetries: Int = 1

    func authenticateWithSIWE(
        appCheckToken: String,
        signing: BackendAuthSigningContext
    ) async throws -> String {
        let deviceId = DeviceInfo.deviceIdentifier
        let slot = KeychainAccount.siweJwt(deviceId: deviceId, address: signing.address)

        // Reuse a cached SIWE JWT as long as it's valid AND actually
        // carries an accountId (legacy device-only tokens would not).
        if let existing = try? keychainService.retrieveString(account: slot),
           !existing.isEmpty,
           isJWTValid(existing),
           Self.jwtCarriesAccountId(existing) {
            Log.info("Using existing SIWE JWT from keychain (address-scoped slot)")
            return existing
        }

        var lastError: (any Error)?
        for attempt in 0...Self.maxSIWENonceRetries {
            do {
                return try await singleSIWEExchange(
                    appCheckToken: appCheckToken,
                    signing: signing,
                    deviceId: deviceId,
                    slot: slot
                )
            } catch SIWEAuthError.invalidNonceOrSignature(let msg) {
                lastError = SIWEAuthError.invalidNonceOrSignature(msg)
                if attempt < Self.maxSIWENonceRetries {
                    Log.info("SIWE 401 on attempt \(attempt + 1); retrying with a fresh nonce")
                    continue
                }
            } catch SIWEAuthError.rateLimited {
                lastError = SIWEAuthError.rateLimited
                if attempt < Self.maxSIWENonceRetries {
                    let delay = TimeInterval.calculateExponentialBackoff(for: attempt)
                    Log.info("SIWE rate-limited; sleeping \(delay)s and retrying from nonce")
                    try await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
                    continue
                }
            }
            break
        }
        throw lastError ?? SIWEAuthError.invalidNonceOrSignature(nil)
    }

    private func singleSIWEExchange(
        appCheckToken: String,
        signing: BackendAuthSigningContext,
        deviceId: String,
        slot: String
    ) async throws -> String {
        let challenge = try await requestAuthNonce(appCheckToken: appCheckToken, retryCount: 0)

        let siweConfig = environment.siweConfiguration
        let message = SIWEMessage(
            domain: siweConfig.domain,
            address: signing.address,
            statement: "Sign in to Convos",
            uri: siweConfig.uri,
            chainId: siweConfig.chainId,
            nonce: challenge.nonce,
            issuedAt: Date(),
            expirationTime: Date().addingTimeInterval(5 * 60),
            // EIP-4361 requires that any additional context appear in
            // the Resources list as valid URIs. We bind the deviceId
            // into the signed message via a custom scheme so the
            // backend can prove the signer authorized exactly this
            // device — must match the `deviceId` in the request body.
            resources: ["convos://device/\(deviceId)"]
        ).prepareMessage()

        let signature = SIWESigner.hexEncoded(try await signing.sign(message))

        let token = try await exchangeSIWE(
            appCheckToken: appCheckToken,
            deviceId: deviceId,
            message: message,
            signatureHex: signature,
            cookieHeader: challenge.cookieHeader
        )

        guard Self.jwtCarriesAccountId(token) else {
            // Backend returned a token without accountId. Treat as a hard
            // failure so we never store a non-SIWE token in the SIWE slot.
            throw SIWEAuthError.tokenMissingAccountId
        }

        try keychainService.saveString(token, account: slot)
        // Persist accountId in its own slot so the UI / debug tools
        // can show it even when the JWT has expired and hasn't been
        // refreshed yet. JWT remains the source of truth for the
        // network identity check; this slot is a UX cache.
        let accountId = BackendAuthProbe.extractAccountId(from: token)
        if let accountId {
            let accountSlot = KeychainAccount.siweAccountId(deviceId: deviceId, address: signing.address)
            try? keychainService.saveString(accountId, account: accountSlot)
        }
        Log.info("Stored SIWE JWT under address-scoped slot (accountId=\(accountId ?? "?"))")
        return token
    }

    func accountAuthCheck(jwt: String?) async throws -> ConvosAPI.AuthCheckResponse {
        let url = baseURL.appendingPathComponent("v2/account-auth-check")
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        if let jwt, !jwt.isEmpty {
            request.setValue(jwt, forHTTPHeaderField: "X-Convos-AuthToken")
        }

        let (data, response) = try await Self.siweSession.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw APIError.invalidResponse
        }

        switch httpResponse.statusCode {
        case 200:
            return try JSONDecoder().decode(ConvosAPI.AuthCheckResponse.self, from: data)
        case 401:
            throw APIError.notAuthenticated
        case 403:
            throw APIError.forbidden
        default:
            throw APIError.serverError(parseErrorMessage(from: data))
        }
    }

    // MARK: - Internals

    /// Dedicated URLSession with cookie storage disabled. SIWE's
    /// `__Host-` nonce cookie must be carried manually as the `Cookie`
    /// header on `/auth/token` — see `ConvosAPIClient+SIWECookieParsing`.
    private static let siweSession: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.httpCookieStorage = nil
        config.httpShouldSetCookies = false
        config.httpCookieAcceptPolicy = .never
        return URLSession(configuration: config)
    }()

    func requestAuthNonce(appCheckToken: String, retryCount: Int) async throws -> AuthNonceChallenge {
        let url = baseURL.appendingPathComponent("v2/auth/nonce")
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue(appCheckToken, forHTTPHeaderField: "X-Firebase-AppCheck")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = Data("{}".utf8)

        let (data, response) = try await Self.siweSession.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw APIError.invalidResponse
        }

        if httpResponse.statusCode == 429 {
            guard retryCount < maxRetryCount else { throw APIError.rateLimitExceeded }
            let delay = TimeInterval.calculateExponentialBackoff(for: retryCount)
            try await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            return try await requestAuthNonce(appCheckToken: appCheckToken, retryCount: retryCount + 1)
        }

        guard httpResponse.statusCode == 200 else {
            let message = parseErrorMessage(from: data) ?? "status \(httpResponse.statusCode)"
            Log.error("Nonce request failed: \(message)")
            throw SIWEAuthError.nonceRequestFailed(httpResponse.statusCode, message)
        }

        let cookie = try Self.extractNonceCookie(from: httpResponse, requestURL: url)
        return cookie
    }

    private func exchangeSIWE(
        appCheckToken: String,
        deviceId: String,
        message: String,
        signatureHex: String,
        cookieHeader: String
    ) async throws -> String {
        let url = baseURL.appendingPathComponent("v2/auth/token")
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue(appCheckToken, forHTTPHeaderField: "X-Firebase-AppCheck")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(cookieHeader, forHTTPHeaderField: "Cookie")

        let body = ConvosAPI.AuthTokenRequest(
            deviceId: deviceId,
            siwe: ConvosAPI.SIWEPayload(message: message, signature: signatureHex)
        )
        request.httpBody = try JSONEncoder().encode(body)

        let (data, response) = try await Self.siweSession.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw APIError.invalidResponse
        }

        guard httpResponse.statusCode == 200 else {
            throw Self.siweExchangeFailure(statusCode: httpResponse.statusCode, data: data)
        }
        return try JSONDecoder().decode(ConvosAPI.AuthTokenResponse.self, from: data).token
    }

    /// Maps a non-200 `/v2/auth/token` response to a typed error.
    ///
    /// The deletion barrier's terminal response is keyed on the envelope's
    /// machine-readable `code` (`identity_deleted`, shipped with status 410),
    /// never on the status or the display string. It is the only mint-path
    /// signal a client may treat as account-deletion confirmation, and it
    /// must never be conflated with the generic 401 nonce/signature failure
    /// (which can equally mean nonce, signature, or service problems).
    ///
    /// Static and pure so it can be unit-tested without a network.
    static func siweExchangeFailure(statusCode: Int, data: Data) -> any Error {
        if BackendErrorEnvelope.parse(from: data)?.code == BackendErrorCode.identityDeleted {
            return SIWEAuthError.identityDeleted
        }
        switch statusCode {
        case 400:
            return APIError.badRequest(parseErrorMessage(from: data))
        case 401:
            // Per backend, the nonce is burned even on signature failure.
            // Signal the caller to restart from /auth/nonce.
            return SIWEAuthError.invalidNonceOrSignature(parseErrorMessage(from: data))
        case 403:
            return SIWEAuthError.deviceDisabled(parseErrorMessage(from: data))
        case 429:
            // Same here: nonce is burned. Caller decides whether to
            // sleep + retry; we just signal.
            return SIWEAuthError.rateLimited
        default:
            return APIError.serverError(parseErrorMessage(from: data))
        }
    }

    // MARK: - Helpers
    //
    // Cookie parsing helpers live in `ConvosAPIClient+SIWECookieParsing.swift`.

    static func jwtCarriesAccountId(_ token: String) -> Bool {
        let parts = token.split(separator: ".")
        guard parts.count == 3 else {
            Log.warning("jwtCarriesAccountId: token does not have 3 segments")
            return false
        }
        let payloadData: Data
        do {
            payloadData = try String(parts[1]).base64URLDecoded()
        } catch {
            Log.warning("jwtCarriesAccountId: base64url decode failed: \(error.localizedDescription)")
            return false
        }
        guard let json = try? JSONSerialization.jsonObject(with: payloadData) as? [String: Any] else {
            Log.warning("jwtCarriesAccountId: payload is not a JSON object")
            return false
        }
        if let id = json["accountId"] as? String, !id.isEmpty { return true }
        return false
    }
}

// MARK: - SIWE-specific errors

public enum SIWEAuthError: Error, CustomStringConvertible {
    case nonceRequestFailed(Int, String)
    case missingNonceCookie
    case malformedNonce
    case invalidNonceOrSignature(String?)
    case deviceDisabled(String?)
    case rateLimited
    case tokenMissingAccountId
    /// Terminal: the deletion barrier is active for this identity. The
    /// account was deleted; no token can ever be minted for these keys
    /// again. Confirms an in-flight deletion whose outcome was ambiguous;
    /// outside a deletion flow it means a paired device's account is gone.
    case identityDeleted

    public var description: String {
        switch self {
        case let .nonceRequestFailed(status, msg):
            return "SIWE nonce request failed (\(status)): \(msg)"
        case .missingNonceCookie:
            return "SIWE nonce cookie missing from response"
        case .malformedNonce:
            return "SIWE nonce cookie value malformed"
        case .invalidNonceOrSignature(let msg):
            return "SIWE rejected by backend: \(msg ?? "Invalid SIWE")"
        case .deviceDisabled(let msg):
            return "Device disabled: \(msg ?? "unknown")"
        case .rateLimited:
            return "SIWE rate limited; retry from /auth/nonce"
        case .tokenMissingAccountId:
            return "Backend returned token without accountId claim"
        case .identityDeleted:
            return "Identity deleted: the backend's deletion barrier is active for this identity"
        }
    }
}

// MARK: - Test seam for hex encoding

extension SIWESigner {
    /// Hex-encodes a 65-byte signature (already v-normalized) for wire
    /// transport.
    public static func hexEncoded(_ signature: Data) -> String {
        "0x" + signature.map { String(format: "%02x", $0) }.joined()
    }
}
