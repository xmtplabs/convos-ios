@testable import ConvosInvitesCore
import Foundation
import Testing

@Suite("URL Invite Code Parsing")
struct URLParsingTests {
    @Test("Parse v2 query param format")
    func parseV2Format() throws {
        let url = try #require(URL(string: "https://dev.convos.org/v2?i=abc123def"))
        #expect(url.convosInviteCode == "abc123def")
    }

    @Test("Parse v2 format with production domain")
    func parseV2Production() throws {
        let url = try #require(URL(string: "https://popup.convos.org/v2?i=slug456"))
        #expect(url.convosInviteCode == "slug456")
    }

    @Test("Parse v2 format ignores empty code")
    func parseV2EmptyCode() throws {
        let url = try #require(URL(string: "https://dev.convos.org/v2?i="))
        #expect(url.convosInviteCode == nil)
    }

    @Test("Parse v2 format without i param returns nil")
    func parseV2NoParam() throws {
        let url = try #require(URL(string: "https://dev.convos.org/v2?other=value"))
        #expect(url.convosInviteCode == nil)
    }

    @Test("Parse path-based format /i/code")
    func parsePathFormat() throws {
        let url = try #require(URL(string: "https://convos.org/i/abc123"))
        #expect(url.convosInviteCode == "abc123")
    }

    @Test("Parse convos:// scheme join format")
    func parseConvosSchemeJoin() throws {
        let url = try #require(URL(string: "convos://join/abc123"))
        #expect(url.convosInviteCode == "abc123")
    }

    @Test("Parse convos:// scheme invite format")
    func parseConvosSchemeInvite() throws {
        let url = try #require(URL(string: "convos://invite/abc123"))
        #expect(url.convosInviteCode == "abc123")
    }

    @Test("Parse query param format ?code=")
    func parseQueryCodeFormat() throws {
        let url = try #require(URL(string: "https://convos.org/invite?code=abc123"))
        #expect(url.convosInviteCode == "abc123")
    }

    @Test("Non-matching URL returns nil")
    func nonMatchingUrl() throws {
        let url = try #require(URL(string: "https://example.com/page"))
        #expect(url.convosInviteCode == nil)
    }

    @Test("HTTP scheme returns nil")
    func httpScheme() throws {
        let url = try #require(URL(string: "http://convos.org/i/abc123"))
        #expect(url.convosInviteCode == nil)
    }

    @Test("Code with URL-safe Base64 characters preserved")
    func urlSafeBase64Chars() throws {
        let code = "Cm8KPwH35JrN-_PiLz+KakFDHsS3KIUdHF1zodJw"
        let url = try #require(URL(string: "https://dev.convos.org/v2?i=\(code)"))
        #expect(url.convosInviteCode == code)
    }
}
