import XCTest
@testable import Convos

final class InviteURLDetectorTests: XCTestCase {
    private var associatedDomains: [String] {
        ConfigManager.shared.associatedDomains
    }

    private var primaryDomain: String {
        ConfigManager.shared.associatedDomain
    }

    private var appUrlScheme: String {
        ConfigManager.shared.appUrlScheme
    }

    // MARK: - Empty and Whitespace Input

    func testEmptyStringReturnsNil() {
        let result = InviteURLDetector.detectInviteURL(in: "")
        XCTAssertNil(result)
    }

    func testWhitespaceOnlyReturnsNil() {
        XCTAssertNil(InviteURLDetector.detectInviteURL(in: "   "))
        XCTAssertNil(InviteURLDetector.detectInviteURL(in: "\n\n"))
        XCTAssertNil(InviteURLDetector.detectInviteURL(in: "\t  \n"))
    }

    func testPlainTextReturnsNil() {
        XCTAssertNil(InviteURLDetector.detectInviteURL(in: "hello world"))
        XCTAssertNil(InviteURLDetector.detectInviteURL(in: "just some regular text without any URLs"))
    }

    // MARK: - HTTPS Invite URLs

    func testValidHTTPSInviteURL_PrimaryDomain() {
        let code = "abc123def456"
        let url = "https://\(primaryDomain)/i/\(code)"
        let result = InviteURLDetector.detectInviteURL(in: url)

        XCTAssertNotNil(result)
        XCTAssertEqual(result?.code, code)
    }

    func testValidHTTPSInviteURL_AllAssociatedDomains() {
        let code = "testcode789"
        for domain in associatedDomains {
            let url = "https://\(domain)/i/\(code)"
            let result = InviteURLDetector.detectInviteURL(in: url)

            XCTAssertNotNil(result, "Should detect invite URL for domain: \(domain)")
            XCTAssertEqual(result?.code, code, "Should extract correct code for domain: \(domain)")
        }
    }

    func testHTTPSInviteURL_WrongDomain() {
        let result = InviteURLDetector.detectInviteURL(in: "https://example.com/i/abc123")
        XCTAssertNil(result)
    }

    func testHTTPSInviteURL_WrongPath() {
        let url = "https://\(primaryDomain)/other/path"
        let result = InviteURLDetector.detectInviteURL(in: url)
        XCTAssertNil(result)
    }

    func testHTTPSInviteURL_QueryParamFormat() {
        let code = "testcode123"
        let url = "https://\(primaryDomain)/invite?code=\(code)"
        let result = InviteURLDetector.detectInviteURL(in: url)

        XCTAssertNotNil(result)
        XCTAssertEqual(result?.code, code)
    }

    // MARK: - Custom URL Scheme

    func testCustomSchemeInviteURL_NotDetectedByNSDataDetector() {
        let code = "invitecode456"
        let url = "\(appUrlScheme)://invite/\(code)"
        let result = InviteURLDetector.detectInviteURL(in: url)

        // NSDataDetector does not detect custom URL schemes, so this returns nil
        // unless the text happens to look like a raw invite code
        XCTAssertNil(result)
    }

    func testWrongSchemeReturnsNil() {
        let result = InviteURLDetector.detectInviteURL(in: "otherscheme://invite/abc123")
        XCTAssertNil(result)
    }

    // MARK: - URL Embedded in Text

    func testInviteURLEmbeddedInText() {
        let code = "embeddedcode789"
        let text = "Hey check out this invite: https://\(primaryDomain)/i/\(code) and let me know"
        let result = InviteURLDetector.detectInviteURL(in: text)

        XCTAssertNotNil(result)
        XCTAssertEqual(result?.code, code)
    }

    func testNonInviteURLInTextReturnsNil() {
        let text = "Check out https://google.com for more info"
        let result = InviteURLDetector.detectInviteURL(in: text)
        XCTAssertNil(result)
    }

    // MARK: - isLikelyInviteCode

    func testIsLikelyInviteCode_ValidLongBase64URL() {
        let longCode = String(repeating: "a", count: 50)
        XCTAssertTrue(InviteURLDetector.isLikelyInviteCode(longCode))
    }

    func testIsLikelyInviteCode_TooShort() {
        let shortCode = String(repeating: "a", count: 49)
        XCTAssertFalse(InviteURLDetector.isLikelyInviteCode(shortCode))
    }

    func testIsLikelyInviteCode_ExactMinimumLength() {
        let code = String(repeating: "A", count: 50)
        XCTAssertTrue(InviteURLDetector.isLikelyInviteCode(code))
    }

    func testIsLikelyInviteCode_InvalidCharacters() {
        let codeWithSpaces = String(repeating: "a", count: 50) + " "
        XCTAssertFalse(InviteURLDetector.isLikelyInviteCode(codeWithSpaces))

        let codeWithSpecial = String(repeating: "a", count: 50) + "!"
        XCTAssertFalse(InviteURLDetector.isLikelyInviteCode(codeWithSpecial))

        let codeWithAt = String(repeating: "a", count: 50) + "@"
        XCTAssertFalse(InviteURLDetector.isLikelyInviteCode(codeWithAt))
    }

    func testIsLikelyInviteCode_AllowsBase64URLCharacters() {
        let code = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwx"
        XCTAssertEqual(code.count, 50)
        XCTAssertTrue(InviteURLDetector.isLikelyInviteCode(code))
    }

    func testIsLikelyInviteCode_AllowsHyphensAndUnderscores() {
        let code = String(repeating: "a-b_c", count: 10)
        XCTAssertTrue(InviteURLDetector.isLikelyInviteCode(code))
    }

    func testIsLikelyInviteCode_AllowsAsterisks() {
        let code = String(repeating: "a*b", count: 17)
        XCTAssertTrue(InviteURLDetector.isLikelyInviteCode(code))
    }

    func testIsLikelyInviteCode_AllowsDigits() {
        let code = String(repeating: "0123456789", count: 5)
        XCTAssertTrue(InviteURLDetector.isLikelyInviteCode(code))
    }

    func testIsLikelyInviteCode_EmptyString() {
        XCTAssertFalse(InviteURLDetector.isLikelyInviteCode(""))
    }

    // MARK: - removeInviteURL

    func testRemoveInviteURL_RemovesURLFromText() {
        let text = "Check this https://example.com/invite out"
        let urlStart = text.index(text.startIndex, offsetBy: 11)
        let urlEnd = text.index(text.startIndex, offsetBy: 37)
        let urlRange = urlStart..<urlEnd

        let result = InviteURLDetector.removeInviteURL(from: text, range: urlRange)
        XCTAssertEqual(result, "Check this  out")
    }

    func testRemoveInviteURL_EntireTextIsURL() {
        let text = "https://example.com/invite"
        let range = text.startIndex..<text.endIndex

        let result = InviteURLDetector.removeInviteURL(from: text, range: range)
        XCTAssertEqual(result, "")
    }

    func testRemoveInviteURL_URLAtStart() {
        let text = "https://example.com/invite hello"
        let urlEnd = text.index(text.startIndex, offsetBy: 26)
        let range = text.startIndex..<urlEnd

        let result = InviteURLDetector.removeInviteURL(from: text, range: range)
        XCTAssertEqual(result, "hello")
    }

    func testRemoveInviteURL_URLAtEnd() {
        let text = "hello https://example.com/invite"
        let urlStart = text.index(text.startIndex, offsetBy: 6)
        let range = urlStart..<text.endIndex

        let result = InviteURLDetector.removeInviteURL(from: text, range: range)
        XCTAssertEqual(result, "hello")
    }

    func testRemoveInviteURL_TrimsWhitespace() {
        let text = "  https://example.com/invite  "
        let urlStart = text.index(text.startIndex, offsetBy: 2)
        let urlEnd = text.index(text.startIndex, offsetBy: 28)
        let range = urlStart..<urlEnd

        let result = InviteURLDetector.removeInviteURL(from: text, range: range)
        XCTAssertEqual(result, "")
    }

    // MARK: - Range Accuracy

    func testDetectedRangeIsAccurate() {
        let code = "testrange123"
        let prefix = "before "
        let suffix = " after"
        let url = "https://\(primaryDomain)/i/\(code)"
        let text = "\(prefix)\(url)\(suffix)"

        let result = InviteURLDetector.detectInviteURL(in: text)
        XCTAssertNotNil(result)

        guard let detectedRange = result?.range else {
            XCTFail("Expected range in result")
            return
        }

        let extractedURL = String(text[detectedRange])
        XCTAssertTrue(extractedURL.contains(primaryDomain))
        XCTAssertTrue(extractedURL.contains(code))
    }

    func testDetectedRangeIsValidOnOriginalText_WithLeadingWhitespace() {
        let code = "rangetest456"
        let text = "   https://\(primaryDomain)/i/\(code) some text"

        let result = InviteURLDetector.detectInviteURL(in: text)
        XCTAssertNotNil(result)

        guard let detectedRange = result?.range else {
            XCTFail("Expected range in result")
            return
        }

        let extracted = String(text[detectedRange])
        XCTAssertTrue(extracted.contains(code))

        let cleaned = InviteURLDetector.removeInviteURL(from: text, range: detectedRange)
        XCTAssertEqual(cleaned, "some text")
    }

    func testDetectedRangeIsValidOnOriginalText_WithSurroundingWhitespace() {
        let code = "rangetest789"
        let text = "\n  https://\(primaryDomain)/i/\(code)  \n"

        let result = InviteURLDetector.detectInviteURL(in: text)
        XCTAssertNotNil(result)

        guard let detectedRange = result?.range else {
            XCTFail("Expected range in result")
            return
        }

        let extracted = String(text[detectedRange])
        XCTAssertTrue(extracted.contains(code))

        let cleaned = InviteURLDetector.removeInviteURL(from: text, range: detectedRange)
        XCTAssertEqual(cleaned, "")
    }

    // MARK: - Edge Cases

    func testHTTPWithoutS_ReturnsNil() {
        let result = InviteURLDetector.detectInviteURL(in: "http://\(primaryDomain)/i/code123")
        XCTAssertNil(result)
    }

    func testMultipleURLs_ReturnsFirstInvite() {
        let code = "firstinvite123"
        let text = "https://google.com https://\(primaryDomain)/i/\(code) https://\(primaryDomain)/i/secondcode"
        let result = InviteURLDetector.detectInviteURL(in: text)

        XCTAssertNotNil(result)
        XCTAssertEqual(result?.code, code)
    }

    func testURLWithLeadingAndTrailingWhitespace() {
        let code = "whitespace123"
        let url = "  https://\(primaryDomain)/i/\(code)  "
        let result = InviteURLDetector.detectInviteURL(in: url)

        XCTAssertNotNil(result)
        XCTAssertEqual(result?.code, code)
    }

    func testURLWithNewlines() {
        let code = "newline123"
        let url = "\nhttps://\(primaryDomain)/i/\(code)\n"
        let result = InviteURLDetector.detectInviteURL(in: url)

        XCTAssertNotNil(result)
        XCTAssertEqual(result?.code, code)
    }
}
