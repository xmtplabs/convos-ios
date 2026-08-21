@testable import ConvosCore
import Foundation
import Testing

@Suite("AgentRelay transports", .serialized)
struct AgentRelayTransportTests {
    @Test("webhook transport sends the Town bearer header")
    func webhookAddsBearerHeader() async throws {
        defer { StubURLProtocol.reset() }
        StubURLProtocol.install { request in
            try response(for: request, status: 204)
        }
        let transport = AgentWebhookURLSessionTransport(configuration: stubConfiguration())

        try await transport.trigger(payload: payload(), url: webhookURL(), auth: .bearer(secret: "top-secret"))

        #expect(StubURLProtocol.requests.count == 1)
        #expect(StubURLProtocol.requests.first?.value(forHTTPHeaderField: "Authorization") == "Bearer top-secret")
    }

    @Test("webhook transport omits auth for a capability URL")
    func webhookOmitsCapabilityAuthHeader() async throws {
        defer { StubURLProtocol.reset() }
        StubURLProtocol.install { request in
            try response(for: request, status: 202)
        }
        let transport = AgentWebhookURLSessionTransport(configuration: stubConfiguration())

        try await transport.trigger(payload: payload(), url: webhookURL(), auth: .capabilityURL)

        #expect(StubURLProtocol.requests.first?.value(forHTTPHeaderField: "Authorization") == nil)
    }

    @Test("webhook transport rejects a redirect without issuing a second request")
    func webhookRefusesRedirect() async {
        defer { StubURLProtocol.reset() }
        let redirectedRequest = URLRequest(url: URL(string: "https://redirected.example.com/webhook") ?? webhookURL())
        #expect(AgentWebhookURLSessionTransport.RedirectRefusingDelegate.redirectedRequest(for: redirectedRequest) == nil)
        StubURLProtocol.install { request in
            try response(
                for: request,
                status: 307,
                headers: ["Location": "https://redirected.example.com/webhook"]
            )
        }
        let transport = AgentWebhookURLSessionTransport(configuration: stubConfiguration())

        await #expect(throws: AgentWebhookTransportError.rejected(status: 307)) {
            try await transport.trigger(payload: payload(), url: webhookURL(), auth: .bearer(secret: "top-secret"))
        }
        #expect(StubURLProtocol.requests.count == 1)
    }

    @Test("HTTP fetch sends wait_ms on its dedicated session")
    func fetchSetsWaitMilliseconds() async throws {
        defer { StubURLProtocol.reset() }
        StubURLProtocol.install { request in
            let data = Data(#"{"status":"pending","requestId":"request_wait","expiresAt":"2026-08-20T18:00:00Z"}"#.utf8)
            let response = try response(for: request, status: 202)
            return (response.0, data)
        }
        let api = AgentRelayHTTPAPI(apiClient: RecordingAuthorizedAPIClient(), configuration: stubConfiguration())

        _ = try await api.fetch(requestId: "request_wait", waitMs: 25_000)

        let request = try #require(StubURLProtocol.requests.first)
        let components = try #require(URLComponents(url: request.url ?? webhookURL(), resolvingAgainstBaseURL: false))
        #expect(components.queryItems?.first(where: { $0.name == "wait_ms" })?.value == "25000")
    }

    @Test("HTTP API owns the 35 second request timeout")
    func longPollSessionHasExpectedTimeout() {
        let api = AgentRelayHTTPAPI(apiClient: RecordingAuthorizedAPIClient(), configuration: stubConfiguration())
        #expect(api.session.configuration.timeoutIntervalForRequest == 35)
    }

    @Test("HTTP mint encodes the provider and decodes ISO dates")
    func mintEncodesProvider() async throws {
        defer { StubURLProtocol.reset() }
        StubURLProtocol.install { request in
            let json = #"{"requestId":"request_mint","returnToken":"return_token","mcpUrl":"https://api.example.com/mcp","expiresAt":"2026-08-20T18:00:00Z"}"#
            let response = try response(for: request, status: 201)
            return (response.0, Data(json.utf8))
        }
        let api = authenticatedRelayAPI()

        let mint = try await api.mint(provider: .tasklet)

        let request = try #require(StubURLProtocol.requests.first)
        let body = try requestBody(request)
        let object = try JSONSerialization.jsonObject(with: body) as? [String: String]
        #expect(object?["provider"] == "tasklet")
        #expect(mint.requestId == "request_mint")
    }

    @Test("HTTP mint surfaces success after authenticated retry")
    func mintRetriesTransientUnauthorizedResponse() async throws {
        defer { StubURLProtocol.reset() }
        StubURLProtocol.install { request in
            try response(for: request, status: 401)
        }
        let executor = RetryingMintExecutor()
        let api = AgentRelayHTTPAPI(
            apiClient: RecordingAuthorizedAPIClient(),
            configuration: stubConfiguration(),
            authenticatedRequestExecutor: executor.perform
        )

        let mint = try await api.mint(provider: .town)

        #expect(mint.requestId == "request_retried")
        #expect(executor.statuses == [401, 201])
        #expect(StubURLProtocol.requests.isEmpty)
    }

    @Test("HTTP completed listing uses the entry completedAt")
    func completedListingMapsEntryDate() async throws {
        defer { StubURLProtocol.reset() }
        StubURLProtocol.install { request in
            let json = #"{"requests":[{"requestId":"request_list","provider":"town","completedAt":"2026-08-20T18:00:00Z","result":{"message":"Listed","links":[]}}]}"#
            let response = try response(for: request, status: 200)
            return (response.0, Data(json.utf8))
        }
        let api = authenticatedRelayAPI()

        let entries = try await api.listCompleted()

        #expect(entries.count == 1)
        #expect(entries.first?.requestId == "request_list")
        #expect(entries.first?.result.message == "Listed")
        #expect(entries.first?.result.completedAt == ISO8601DateFormatter().date(from: "2026-08-20T18:00:00Z"))
    }

    @Test("Mock API client supplies its default JWT header")
    func mockAPIClientAddsDefaultJWT() async throws {
        let request = try await MockAPIClient().authorizedRequest(
            for: "v2/agent-relay/requests",
            method: "GET",
            queryParameters: nil
        )
        #expect(request.value(forHTTPHeaderField: "X-Convos-AuthToken") == "mock-jwt-token")
    }

    @Test("Mock API client prefers an override JWT header")
    func mockAPIClientAddsOverrideJWT() async throws {
        let request = try await MockAPIClient(overrideJWTToken: "scoped-jwt").authorizedRequest(
            for: "v2/agent-relay/requests/request_push",
            method: "GET",
            queryParameters: nil
        )
        #expect(request.value(forHTTPHeaderField: "X-Convos-AuthToken") == "scoped-jwt")
    }

    @Test("a full send never logs webhook secrets or content")
    func sendLogsOnlySafeWebhookMetadata() async throws {
        defer {
            AgentRelayLog.installTestSink(nil)
            StubURLProtocol.reset()
        }
        StubURLProtocol.install { request in
            try response(for: request, status: 204)
        }
        let log = AgentRelayCallRecorder()
        AgentRelayLog.installTestSink { line in
            log.append(line)
        }
        let result = makeAgentRelayResult(message: "safe result")
        let mint = AgentRelayMint(
            requestId: "request_1234567890",
            returnToken: "return-secret",
            mcpUrl: URL(string: "https://api.example.com/mcp") ?? URL(fileURLWithPath: "/mcp"),
            expiresAt: Date().addingTimeInterval(3_600)
        )
        let api = ScriptedAgentRelayAPI(mint: mint, fetchOutcomes: [.completed(result)])
        let webhook = AgentWebhookURLSessionTransport(configuration: stubConfiguration())
        let writer = RecordingAgentChatWriter(recorder: AgentRelayCallRecorder())
        let history = StubAgentHistoryBuilder(
            entries: [AgentWebhookHistoryEntry(role: "user", text: "private history", at: Date())]
        )
        let client = AgentRelayClient(api: api, webhook: webhook, store: writer, history: history)
        let connection = AgentConnection(
            provider: .town,
            webhookURL: webhookURL(),
            auth: .bearer(secret: "top-secret")
        )

        _ = try await client.send(prompt: "private prompt", connection: connection)

        let output = log.calls.joined(separator: "\n")
        #expect(!output.contains("return-secret"))
        #expect(!output.contains("top-secret"))
        #expect(!output.contains("private prompt"))
        #expect(!output.contains("private history"))
        #expect(output.contains("Agent webhook POST 204 request request_1234"))
    }

    private func stubConfiguration() -> URLSessionConfiguration {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubURLProtocol.self]
        return configuration
    }

    private func authenticatedRelayAPI() -> AgentRelayHTTPAPI {
        let configuration = stubConfiguration()
        let authenticatedSession = URLSession(configuration: configuration)
        return AgentRelayHTTPAPI(
            apiClient: RecordingAuthorizedAPIClient(),
            configuration: configuration,
            authenticatedRequestExecutor: { request in
                let (data, response) = try await authenticatedSession.data(for: request)
                guard let httpResponse = response as? HTTPURLResponse else {
                    throw AgentRelayTestError.expected
                }
                return (data, httpResponse)
            }
        )
    }

    private func payload() -> AgentWebhookPayload {
        AgentWebhookPayload(
            requestId: "request_1234567890",
            returnToken: "return-secret",
            prompt: "private prompt",
            history: [AgentWebhookHistoryEntry(role: "user", text: "private history", at: Date())],
            reply: AgentWebhookPayload.Reply(mcpServer: URL(string: "https://api.example.com/mcp") ?? URL(fileURLWithPath: "/mcp"))
        )
    }

    private func webhookURL() -> URL {
        URL(string: "https://hooks.example.com/webhook?capability=secret") ?? URL(fileURLWithPath: "/webhook")
    }
}

private final class RetryingMintExecutor: @unchecked Sendable {
    private let lock: NSLock = NSLock()
    private var storedStatuses: [Int] = []

    var statuses: [Int] {
        lock.withLock { storedStatuses }
    }

    func perform(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let unauthorized = try response(for: request, status: 401).0
        lock.withLock {
            storedStatuses.append(unauthorized.statusCode)
        }

        let json = #"{"requestId":"request_retried","returnToken":"return_token","mcpUrl":"https://api.example.com/mcp","expiresAt":"2026-08-20T18:00:00Z"}"#
        let success = try response(for: request, status: 201).0
        lock.withLock {
            storedStatuses.append(success.statusCode)
        }
        return (Data(json.utf8), success)
    }
}

private final class RecordingAuthorizedAPIClient: TestStubAPIClient, @unchecked Sendable {
    override func authorizedRequest(
        for endpoint: String,
        method: String,
        queryParameters: [String: String]?
    ) async throws -> URLRequest {
        var components = URLComponents(string: "https://api.example.com/api/\(endpoint)")
        components?.queryItems = queryParameters?.map { key, value in
            URLQueryItem(name: key, value: value)
        }
        guard let url = components?.url else { throw AgentRelayTestError.expected }
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.setValue("test-jwt-token", forHTTPHeaderField: "X-Convos-AuthToken")
        return request
    }
}

private func response(
    for request: URLRequest,
    status: Int,
    headers: [String: String]? = nil
) throws -> (HTTPURLResponse, Data) {
    guard let url = request.url,
          let response = HTTPURLResponse(url: url, statusCode: status, httpVersion: "HTTP/1.1", headerFields: headers) else {
        throw AgentRelayTestError.expected
    }
    return (response, Data())
}

private func requestBody(_ request: URLRequest) throws -> Data {
    if let body = request.httpBody {
        return body
    }
    guard let stream = request.httpBodyStream else {
        throw AgentRelayTestError.expected
    }
    stream.open()
    defer { stream.close() }
    var data = Data()
    let capacity = 4_096
    var buffer = [UInt8](repeating: 0, count: capacity)
    while stream.hasBytesAvailable {
        let count = stream.read(&buffer, maxLength: capacity)
        guard count >= 0 else { throw AgentRelayTestError.expected }
        guard count > 0 else { break }
        data.append(buffer, count: count)
    }
    return data
}
