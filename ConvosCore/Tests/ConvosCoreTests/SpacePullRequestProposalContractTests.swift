@testable import ConvosCore
import Foundation
import Testing

@Suite("Space pull request proposal contract")
struct SpacePullRequestProposalContractTests {
    @Test("Request keeps an opaque conversation id in one authenticated path segment")
    func requestContract() throws {
        let client = try makeClient(environment: .local(config: Self.configuration))
        let request = try client.spacePullRequestProposalRequest(
            conversationId: "ab/c%d?e#f",
            variantId: nil
        )

        #expect(request.httpMethod == "POST")
        #expect(
            request.url?.absoluteString ==
                "https://api.example.com/api/v2/conversations/ab%2Fc%25d%3Fe%23f/debug/space-upstream"
        )
        #expect(request.url?.query == nil)
        #expect(request.httpBody == nil)
        #expect(request.timeoutInterval == 55)
        #expect(request.value(forHTTPHeaderField: "X-Convos-AuthToken") == "test-jwt")
    }

    @Test("Non-production requests preserve the cosmetic slug as one encoded query item")
    func nonProductionVariantQuery() throws {
        let client = try makeClient(environment: .dev(config: Self.configuration))
        let slug = "pr 123/qa?x=1"
        let request = try client.spacePullRequestProposalRequest(
            conversationId: "conversation-1",
            variantId: slug
        )
        let url = try #require(request.url)
        let components = try #require(URLComponents(url: url, resolvingAgainstBaseURL: false))

        #expect(components.queryItems == [URLQueryItem(name: "variantId", value: slug)])
        #expect(components.percentEncodedQuery?.contains("variantId=") == true)
        #expect(components.percentEncodedQuery?.contains("%20") == true)
        #expect(components.percentEncodedQuery?.contains("%3D") == true)
    }

    @Test("Production drops the cosmetic slug")
    func productionVariantOmission() throws {
        let client = try makeClient(environment: .production(config: Self.configuration))
        let request = try client.spacePullRequestProposalRequest(
            conversationId: "conversation-1",
            variantId: "pr-1234"
        )

        #expect(request.url?.query == nil)
    }

    @Test("Pull request success decodes the backend envelope and exposes only a validated HTTPS URL")
    func pullRequestDecode() throws {
        let data = try #require("""
        {
          "success": true,
          "conversationId": "conversation-1",
          "outcome": "pull_request",
          "prUrl": "https://github.com/xmtplabs/convos-assistants/pull/123",
          "prNumber": 123,
          "branch": "space-upstream/conversation-1",
          "commitSha": "commit-1",
          "forkCommitSha": "fork-1",
          "wrote": 0,
          "deleted": 0,
          "refusedCount": 0
        }
        """.data(using: .utf8))
        let outcome = try ConvosAPIClient.decodeSpacePullRequestProposalOutcome(data)

        guard case .pullRequest(let pullRequest) = outcome else {
            Issue.record("Expected pull_request outcome")
            return
        }
        #expect(pullRequest.conversationId == "conversation-1")
        #expect(pullRequest.prURL.absoluteString == "https://github.com/xmtplabs/convos-assistants/pull/123")
        #expect(pullRequest.refusedCount == 0)
    }

    @Test("Unchanged success decodes the backend envelope")
    func unchangedDecode() throws {
        let data = try #require("""
        {
          "success": true,
          "conversationId": "conversation-1",
          "outcome": "unchanged",
          "forkCommitSha": "fork-1",
          "wrote": 0,
          "deleted": 0,
          "refusedCount": 0
        }
        """.data(using: .utf8))
        let outcome = try ConvosAPIClient.decodeSpacePullRequestProposalOutcome(data)

        guard case .unchanged(let unchanged) = outcome else {
            Issue.record("Expected unchanged outcome")
            return
        }
        #expect(unchanged.conversationId == "conversation-1")
        #expect(unchanged.refusedCount == 0)
    }

    @Test("Success decoding ignores additive fields")
    func additiveSuccessDecode() throws {
        let data = try #require("""
        {
          "success": true,
          "conversationId": "conversation-1",
          "outcome": "unchanged",
          "forkCommitSha": "fork-1",
          "wrote": 0,
          "deleted": 0,
          "refusedCount": 0,
          "futureField": { "isIgnored": true }
        }
        """.data(using: .utf8))

        guard case .unchanged = try ConvosAPIClient.decodeSpacePullRequestProposalOutcome(data) else {
            Issue.record("Expected unchanged outcome")
            return
        }
    }

    @Test("Pull request decode rejects non-HTTPS and hostless URLs")
    func pullRequestURLValidation() throws {
        for prURL in ["http://github.com/x/pull/1", "https:///pull/1"] {
            let data = try #require("""
            {
              "success": true,
              "conversationId": "conversation-1",
              "outcome": "pull_request",
              "prUrl": "\(prURL)",
              "prNumber": 1,
              "branch": "space-upstream/conversation-1",
              "commitSha": "commit-1",
              "forkCommitSha": "fork-1",
              "wrote": 1,
              "deleted": 0,
              "refusedCount": 0
            }
            """.data(using: .utf8))
            #expect(throws: ConvosAPI.SpacePullRequestProposalDecodingError.invalidPullRequestURL) {
                _ = try ConvosAPIClient.decodeSpacePullRequestProposalOutcome(data)
            }
        }
    }

    @Test("Every backend error code maps to its typed client error")
    func typedErrorDecode() throws {
        let cases: [(String, ConvosAPI.SpacePullRequestProposalError)] = [
            ("INVALID_REQUEST", .invalidRequest),
            ("VARIANT_UNAVAILABLE", .variantUnavailable),
            ("SPACE_NOT_FOUND", .spaceNotFound),
            ("SPACE_REPOSITORY_UNAVAILABLE", .repositoryUnavailable),
            ("SPACE_UPSTREAM_NOT_ARMED", .notArmed),
            ("SPACE_UPSTREAM_UNAVAILABLE", .unavailable),
            ("SPACE_UPSTREAM_REFUSED", .refused),
            ("SPACE_UPSTREAM_GITHUB_FAILED", .githubFailed),
            ("SPACE_UPSTREAM_FAILED", .failed),
            ("SPACE_UPSTREAM_TIMEOUT", .timeout),
            ("RATE_LIMITED", .rateLimited)
        ]

        for (code, expected) in cases {
            let data = try #require(
                #"{"success":false,"error":"\#(code)","message":"human-readable message"}"#.data(using: .utf8)
            )
            #expect(ConvosAPIClient.decodeSpacePullRequestProposalError(data) == expected)
        }
    }

    @Test("Unknown and malformed error envelopes fall through")
    func typedErrorFallthrough() throws {
        let unknown = try #require(
            #"{"success":false,"error":"SOMETHING_NEW","message":"new failure"}"#.data(using: .utf8)
        )
        let success = try #require(
            #"{"success":true,"error":"SPACE_UPSTREAM_FAILED","message":"not an error"}"#.data(using: .utf8)
        )
        let legacy = try #require(
            #"{"error":"failed","code":"SPACE_UPSTREAM_FAILED"}"#.data(using: .utf8)
        )

        #expect(ConvosAPIClient.decodeSpacePullRequestProposalError(unknown) == nil)
        #expect(ConvosAPIClient.decodeSpacePullRequestProposalError(success) == nil)
        #expect(ConvosAPIClient.decodeSpacePullRequestProposalError(legacy) == nil)
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
