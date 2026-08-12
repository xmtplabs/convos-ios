@testable import ConvosCore
import Foundation
import Testing

@Suite("Space pull request proposal contract")
struct SpacePullRequestProposalContractTests {
    @Test("Request is an authenticated bodyless POST with the 55-second budget")
    func requestContract() throws {
        let client = try makeClient(environment: .local(config: Self.configuration))
        let request = try client.spacePullRequestProposalRequest(
            conversationId: "ABC_123-",
            variantId: nil
        )

        #expect(request.httpMethod == "POST")
        #expect(request.url?.path == "/api/v2/conversations/ABC_123-/debug/space-upstream")
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

    @Test("Pull request success decodes additively and exposes only a validated HTTPS URL")
    func pullRequestDecode() throws {
        let data = try #require("""
        {
          "conversationId": "conversation-1",
          "outcome": "pull_request",
          "prUrl": "https://github.com/xmtplabs/convos-assistants/pull/123",
          "prNumber": 123,
          "branch": "space-upstream/conversation-1",
          "commitSha": "commit-1",
          "forkCommitSha": "fork-1",
          "wrote": 4,
          "deleted": 1,
          "refusedCount": 2,
          "futureField": { "isIgnored": true }
        }
        """.data(using: .utf8))
        let outcome = try ConvosAPIClient.decodeSpacePullRequestProposalOutcome(data)

        guard case .pullRequest(let pullRequest) = outcome else {
            Issue.record("Expected pull_request outcome")
            return
        }
        #expect(pullRequest.conversationId == "conversation-1")
        #expect(pullRequest.prURL.absoluteString == "https://github.com/xmtplabs/convos-assistants/pull/123")
        #expect(pullRequest.refusedCount == 2)
    }

    @Test("Unchanged success decodes with additive fields")
    func unchangedDecode() throws {
        let data = try #require("""
        {
          "conversationId": "conversation-1",
          "outcome": "unchanged",
          "forkCommitSha": "fork-1",
          "wrote": 0,
          "deleted": 0,
          "refusedCount": 1,
          "futureField": true
        }
        """.data(using: .utf8))
        let outcome = try ConvosAPIClient.decodeSpacePullRequestProposalOutcome(data)

        guard case .unchanged(let unchanged) = outcome else {
            Issue.record("Expected unchanged outcome")
            return
        }
        #expect(unchanged.conversationId == "conversation-1")
        #expect(unchanged.refusedCount == 1)
    }

    @Test("Pull request decode rejects non-HTTPS and hostless URLs")
    func pullRequestURLValidation() throws {
        for prURL in ["http://github.com/x/pull/1", "https:///pull/1"] {
            let data = try #require("""
            {
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

    @Test("Known error codes normalize while unknown envelopes fall through")
    func typedErrorDecode() throws {
        let lowercased = try #require(#"{"error":"not armed","code":"space_upstream_not_armed"}"#.data(using: .utf8))
        let timeout = try #require(#"{"error":"timed out","code":"SPACE_UPSTREAM_TIMEOUT"}"#.data(using: .utf8))
        let unknown = try #require(#"{"error":"new failure","code":"SOMETHING_NEW"}"#.data(using: .utf8))

        #expect(ConvosAPIClient.decodeSpacePullRequestProposalError(lowercased) == .notArmed)
        #expect(ConvosAPIClient.decodeSpacePullRequestProposalError(timeout) == .timeout)
        #expect(ConvosAPIClient.decodeSpacePullRequestProposalError(unknown) == nil)
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
