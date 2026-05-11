@testable import ConvosCore
import Foundation
import Testing

/// `Set-Cookie` parsing for the SIWE nonce flow. The backend emits
/// `__Host-convos_nonce` in prod with strict attrs (`Secure`,
/// `SameSite=Strict`); we also accept the proposed dev form
/// `convos_nonce` so iOS keeps working whether or not the backend
/// relaxes the cookie attributes outside prod.
@Suite("SIWE nonce cookie parsing")
struct SIWENonceCookieParsingTests {
    @Test("Parses __Host-convos_nonce (prod form) and extracts hex nonce after the HMAC separator")
    func parsesProdCookie() throws {
        let hex = String(repeating: "ab", count: 32) // 64 hex chars
        let hmac = "Sig0_abc-DEF"
        let setCookie = "__Host-convos_nonce=\(hmac).\(hex); Path=/; HttpOnly; Secure; SameSite=Strict; Max-Age=300"
        let response = makeResponse(setCookie: setCookie)
        let challenge = try ConvosAPIClient.extractNonceCookie(from: response, requestURL: requestURL)
        #expect(challenge.nonce == hex)
        #expect(challenge.cookieHeader == "__Host-convos_nonce=\(hmac).\(hex)")
    }

    @Test("Parses relaxed dev form (convos_nonce without Secure)")
    func parsesDevCookie() throws {
        let hex = String(repeating: "cd", count: 32)
        let setCookie = "convos_nonce=hmac.\(hex); Path=/; HttpOnly; SameSite=Lax; Max-Age=300"
        let response = makeResponse(setCookie: setCookie)
        let challenge = try ConvosAPIClient.extractNonceCookie(from: response, requestURL: requestURL)
        #expect(challenge.nonce == hex)
        #expect(challenge.cookieHeader == "convos_nonce=hmac.\(hex)")
    }

    @Test("Finds the nonce cookie when URLSession coalesces multiple Set-Cookie headers and the nonce is second")
    func parsesNonceWhenCoalescedSecond() throws {
        // URLSession concatenates duplicate Set-Cookie headers with
        // ", " when surfacing them through `value(forHTTPHeaderField:)`.
        // The nonce cookie's value contains a `.` separator
        // (`<hmac>.<hex-nonce>`), so any splitter that validates the
        // *value* part of the next chunk against a restricted char set
        // will miss the boundary and parse both cookies as one entry —
        // ending up unable to find the nonce. This regression test
        // pins the fix from the macroscope review on PR #827.
        let hex = String(repeating: "ab", count: 32)
        let coalesced = [
            "analytics_id=abc-123-def; Path=/; HttpOnly",
            "__Host-convos_nonce=hmac+slash/value.\(hex); Path=/; HttpOnly; Secure; SameSite=Strict; Max-Age=300",
        ].joined(separator: ", ")

        let response = makeResponse(setCookie: coalesced)
        let challenge = try ConvosAPIClient.extractNonceCookie(from: response, requestURL: requestURL)
        #expect(challenge.nonce == hex)
        #expect(challenge.cookieHeader == "__Host-convos_nonce=hmac+slash/value.\(hex)")
    }

    @Test("Throws missingNonceCookie when the response has no recognized cookie")
    func throwsWhenAbsent() {
        let response = makeResponse(setCookie: "other_cookie=whatever; Path=/")
        #expect(throws: SIWEAuthError.self) {
            _ = try ConvosAPIClient.extractNonceCookie(from: response, requestURL: requestURL)
        }
    }

    @Test("Throws malformedNonce when the hex part isn't 64 lowercase hex chars")
    func throwsOnMalformedNonce() {
        let setCookie = "convos_nonce=hmac.NOT-HEX; Path=/; HttpOnly; SameSite=Lax"
        let response = makeResponse(setCookie: setCookie)
        #expect(throws: SIWEAuthError.self) {
            _ = try ConvosAPIClient.extractNonceCookie(from: response, requestURL: requestURL)
        }
    }

    // MARK: - Helpers

    private var requestURL: URL {
        guard let url = URL(string: "http://localhost:4000/api/v2/auth/nonce") else {
            fatalError("test url should be valid")
        }
        return url
    }

    private func makeResponse(setCookie: String) -> HTTPURLResponse {
        guard let response = HTTPURLResponse(
            url: requestURL,
            statusCode: 200,
            httpVersion: "HTTP/1.1",
            headerFields: ["Set-Cookie": setCookie]
        ) else {
            fatalError("HTTPURLResponse init should not fail for valid inputs")
        }
        return response
    }
}
