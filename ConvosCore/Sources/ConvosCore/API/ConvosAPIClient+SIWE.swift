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
        signing: BackendAuthSigningContext,
        retryCount: Int = 0
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
            expirationTime: Date().addingTimeInterval(5 * 60)
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
        Log.info("Stored SIWE JWT under address-scoped slot")
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

    struct AuthNonceChallenge {
        let nonce: String           // 64-char lowercase hex
        let cookieHeader: String    // exact `name=value` to send back on /auth/token
    }

    private static let siweSession: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.httpCookieStorage = nil
        config.httpShouldSetCookies = false
        config.httpCookieAcceptPolicy = .never
        return URLSession(configuration: config)
    }()

    private static let nonceCookieNames: [String] = [
        "__Host-convos_nonce",  // prod (strict attrs)
        "convos_nonce",         // proposed relaxed form for non-prod
    ]

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

        switch httpResponse.statusCode {
        case 200:
            return try JSONDecoder().decode(ConvosAPI.AuthTokenResponse.self, from: data).token
        case 400:
            throw APIError.badRequest(parseErrorMessage(from: data))
        case 401:
            // Per backend, the nonce is burned even on signature failure.
            // Signal the caller to restart from /auth/nonce.
            throw SIWEAuthError.invalidNonceOrSignature(parseErrorMessage(from: data))
        case 403:
            throw SIWEAuthError.deviceDisabled(parseErrorMessage(from: data))
        case 429:
            // Same here: nonce is burned. Caller decides whether to
            // sleep + retry; we just signal.
            throw SIWEAuthError.rateLimited
        default:
            throw APIError.serverError(parseErrorMessage(from: data))
        }
    }

    // MARK: - Helpers

    static func extractNonceCookie(
        from response: HTTPURLResponse,
        requestURL: URL
    ) throws -> AuthNonceChallenge {
        // Parse Set-Cookie manually rather than via HTTPCookie. We
        // intentionally don't go through the system cookie parser
        // because (a) HTTPCookie drops `Secure` cookies on `http://`
        // URLs, which is exactly our local-dev case, and (b) we don't
        // need cookie *semantics* — we just need to find the named
        // cookie's raw value and echo it back as the Cookie header.
        let setCookieValue: String
        if let direct = response.value(forHTTPHeaderField: "Set-Cookie") {
            setCookieValue = direct
        } else {
            setCookieValue = response.allHeaderFields
                .first(where: { ($0.key as? String)?.lowercased() == "set-cookie" })?
                .value as? String ?? ""
        }
        guard !setCookieValue.isEmpty else {
            throw SIWEAuthError.missingNonceCookie
        }

        // A response may carry multiple Set-Cookie headers concatenated
        // with ", " when surfaced through allHeaderFields. Each cookie's
        // attributes are `;`-separated, so split on commas only when the
        // following segment starts with a recognized cookie name.
        for entry in splitSetCookieEntries(setCookieValue) {
            // `name=value` is always the first `;`-separated segment.
            let parts = entry.split(separator: ";", maxSplits: 1, omittingEmptySubsequences: false)
            let nameValue = parts[0].trimmingCharacters(in: .whitespaces)
            guard let eq = nameValue.firstIndex(of: "=") else { continue }
            let name = String(nameValue[..<eq])
            let value = String(nameValue[nameValue.index(after: eq)...])
            guard nonceCookieNames.contains(name) else { continue }

            // Cookie value format: `<hmac>.<hex-nonce>`. The hex nonce
            // is the part after the last `.`; tolerate (but don't
            // require) the HMAC prefix.
            let hexNonce: String
            if let dot = value.lastIndex(of: ".") {
                hexNonce = String(value[value.index(after: dot)...])
            } else {
                hexNonce = value
            }
            guard nonceRegex.firstMatch(
                in: hexNonce,
                range: NSRange(location: 0, length: hexNonce.utf16.count)
            ) != nil else {
                throw SIWEAuthError.malformedNonce
            }
            return AuthNonceChallenge(nonce: hexNonce, cookieHeader: "\(name)=\(value)")
        }
        throw SIWEAuthError.missingNonceCookie
    }

    /// Splits a concatenated Set-Cookie header value into individual
    /// cookies. URLSession's `allHeaderFields` joins duplicate
    /// `Set-Cookie` lines with ", ", but commas can also appear inside
    /// cookie *values* (e.g. base64 with `/`, `+`, `=`, or our nonce
    /// cookie's `<hmac>.<hex>` separator) and inside `Expires=...`
    /// dates. We split on `, ` only when the next segment looks like
    /// the start of a new cookie: `name=` where `name` matches the
    /// RFC 6265 cookie-name token grammar (letters, digits, `_`, `-`,
    /// `.`). The value side of `name=value` is intentionally not
    /// validated — anything between `=` and the next `;`/`,` may
    /// appear there.
    private static func splitSetCookieEntries(_ raw: String) -> [String] {
        var entries: [String] = []
        var current = ""
        let scalars = Array(raw)
        var i = 0
        while i < scalars.count {
            if scalars[i] == ",",
               i + 1 < scalars.count,
               scalars[i + 1] == " ",
               Self.headerSeparatorStartsNewCookie(in: scalars, at: i + 2) {
                entries.append(current)
                current = ""
                i += 2
                continue
            }
            current.append(scalars[i])
            i += 1
        }
        if !current.isEmpty { entries.append(current) }
        return entries
    }

    /// Returns `true` if `scalars[start...]` begins with at least one
    /// cookie-name char followed by `=` within a reasonable lookahead.
    /// Cookie name grammar (RFC 6265 §4.1.1): a `token`, which we
    /// approximate here as `[A-Za-z0-9_\-\.]+` — covers every cookie
    /// name the backend emits today (`__Host-convos_nonce`,
    /// `convos_nonce`) and any reasonable future neighbor.
    private static func headerSeparatorStartsNewCookie(
        in scalars: [Character],
        at start: Int
    ) -> Bool {
        let limit = min(scalars.count, start + 80)
        var j = start
        while j < limit {
            let c = scalars[j]
            if c == "=" {
                return j > start
            }
            if c.isLetter || c.isNumber || c == "_" || c == "-" || c == "." {
                j += 1
                continue
            }
            return false
        }
        return false
    }

    private static let nonceRegex: NSRegularExpression = {
        // swiftlint:disable:next force_try
        try! NSRegularExpression(pattern: "^[0-9a-f]{64}$")
    }()

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
