@testable import ConvosCore
import Foundation
import Testing

@Suite("Space share contract")
struct SpaceShareContractTests {
    @Test("Request keeps an opaque conversation id in one authenticated path segment")
    func requestContract() throws {
        let client = try makeClient(environment: .local(config: Self.configuration))
        let request = try client.spaceShareRequest(
            conversationId: "ab/c%d?e#f",
            variantId: nil
        )

        #expect(request.httpMethod == "POST")
        #expect(
            request.url?.absoluteString ==
                "https://api.example.com/api/v2/conversations/ab%2Fc%25d%3Fe%23f/debug/space-share"
        )
        #expect(request.url?.query == nil)
        #expect(request.httpBody == nil)
        #expect(request.timeoutInterval == 30)
        #expect(request.value(forHTTPHeaderField: "X-Convos-AuthToken") == "test-jwt")
    }

    @Test("Non-production requests preserve the cosmetic slug as one encoded query item")
    func nonProductionVariantQuery() throws {
        let client = try makeClient(environment: .dev(config: Self.configuration))
        let slug = "pr 123/qa?x=1"
        let request = try client.spaceShareRequest(
            conversationId: "conversation-1",
            variantId: slug
        )
        let url = try #require(request.url)
        let components = try #require(URLComponents(url: url, resolvingAgainstBaseURL: false))

        #expect(components.queryItems == [URLQueryItem(name: "variantId", value: slug)])
    }

    @Test("Production drops the cosmetic slug")
    func productionVariantOmission() throws {
        let client = try makeClient(environment: .production(config: Self.configuration))
        let request = try client.spaceShareRequest(
            conversationId: "conversation-1",
            variantId: "pr-1234"
        )

        #expect(request.url?.query == nil)
        // The slug must be absent from the whole URL, not merely the query.
        #expect(request.url?.absoluteString.contains("pr-1234") == false)
    }

    @Test("Success decodes the backend envelope")
    func successDecode() throws {
        let data = try #require("""
        {
          "success": true,
          "conversationId": "conversation-1",
          "message": "Import this space using the space-import skill:\\nhttps://user:secret@code.storage/xmtp/repo.git",
          "expiresAt": "2026-08-20T12:00:00.000Z"
        }
        """.data(using: .utf8))
        let link = try ConvosAPIClient.decodeSpaceShareLink(data)

        #expect(link.conversationId == "conversation-1")
        #expect(
            link.message ==
                "Import this space using the space-import skill:\nhttps://user:secret@code.storage/xmtp/repo.git"
        )
        #expect(link.expiresAt == "2026-08-20T12:00:00.000Z")
    }

    @Test("Success decoding ignores additive fields")
    func additiveSuccessDecode() throws {
        let data = try #require("""
        {
          "success": true,
          "conversationId": "conversation-1",
          "message": "Import this space using the space-import skill:\\nhttps://example.invalid/repo.git",
          "expiresAt": "2026-08-20T12:00:00.000Z",
          "futureField": { "isIgnored": true }
        }
        """.data(using: .utf8))

        _ = try ConvosAPIClient.decodeSpaceShareLink(data)
    }

    @Test("A false success envelope is rejected")
    func falseSuccessRejected() throws {
        let data = try #require("""
        {
          "success": false,
          "conversationId": "conversation-1",
          "message": "not a real link",
          "expiresAt": "2026-08-20T12:00:00.000Z"
        }
        """.data(using: .utf8))

        #expect(throws: DecodingError.self) {
            _ = try ConvosAPIClient.decodeSpaceShareLink(data)
        }
    }

    @Test("Every backend error code maps to its typed client error")
    func typedErrorDecode() throws {
        let cases: [(String, ConvosAPI.SpaceShareError)] = [
            ("INVALID_REQUEST", .invalidRequest),
            ("VARIANT_UNAVAILABLE", .variantUnavailable),
            ("SPACE_NOT_FOUND", .spaceNotFound),
            ("SPACE_REPOSITORY_UNAVAILABLE", .repositoryUnavailable),
            ("SPACE_SHARE_UNAVAILABLE", .unavailable),
            ("SPACE_SHARE_FAILED", .failed),
            ("SPACE_SHARE_TIMEOUT", .timeout),
            ("RATE_LIMITED", .rateLimited)
        ]

        for (code, expected) in cases {
            let data = try #require(
                #"{"success":false,"error":"\#(code)","message":"human-readable message"}"#.data(using: .utf8)
            )
            #expect(ConvosAPIClient.decodeSpaceShareError(data) == expected)
        }
    }

    @Test("Unknown and malformed error envelopes fall through")
    func typedErrorFallthrough() throws {
        let unknown = try #require(
            #"{"success":false,"error":"SOMETHING_NEW","message":"new failure"}"#.data(using: .utf8)
        )
        let success = try #require(
            #"{"success":true,"error":"SPACE_SHARE_FAILED","message":"not an error"}"#.data(using: .utf8)
        )
        let legacy = try #require(
            #"{"error":"failed","code":"SPACE_SHARE_FAILED"}"#.data(using: .utf8)
        )

        #expect(ConvosAPIClient.decodeSpaceShareError(unknown) == nil)
        #expect(ConvosAPIClient.decodeSpaceShareError(success) == nil)
        #expect(ConvosAPIClient.decodeSpaceShareError(legacy) == nil)
    }

    private func makeClient(environment: AppEnvironment) throws -> ConvosAPIClient {
        try #require(ConvosAPIClientFactory.client(
            environment: environment,
            overrideJWTToken: "test-jwt"
        ) as? ConvosAPIClient)
    }

    private static let configuration: ConvosConfiguration = ConvosConfiguration(
        apiBaseURL: "https://api.example.com/api",
        appGroupIdentifier: "group.test",
        relyingPartyIdentifier: "example.com",
        siweConfiguration: SIWEConfiguration(
            domain: "example.com",
            uri: "https://example.com",
            chainId: 1
        )
    )
}
