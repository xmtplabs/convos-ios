import Foundation

/// SIWE nonce cookie parsing. Pulled out of `ConvosAPIClient+SIWE.swift`
/// so the auth flow file stays focused on the request/response orchestration
/// and the cookie semantics live alongside their own tests
/// (`SIWENonceCookieParsingTests`).
///
/// Why a manual parser instead of `HTTPCookie.cookies(...)`:
///   - `HTTPCookie` drops `Secure` cookies on `http://` URLs, which is
///     exactly our local-dev case. We need to find the named cookie
///     regardless of its attributes.
///   - We never need cookie *semantics* (Expiry enforcement, Path
///     matching, etc.) — we just echo `name=value` back as the `Cookie`
///     header on `/auth/token`.
extension ConvosAPIClient {
    struct AuthNonceChallenge {
        let nonce: String           // 64-char lowercase hex
        let cookieHeader: String    // exact `name=value` to send back on /auth/token
    }

    static let nonceCookieNames: [String] = [
        "__Host-convos_nonce",  // prod (strict attrs)
        "convos_nonce",         // proposed relaxed form for non-prod
    ]

    static func extractNonceCookie(
        from response: HTTPURLResponse,
        requestURL: URL
    ) throws -> AuthNonceChallenge {
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
}
