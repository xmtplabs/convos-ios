import Foundation

/// The relay's return path on convos-backend: mint, long-poll, ack, and the
/// restart-recovery listing. Implemented over the authenticated API client
/// by `AgentRelayHTTPAPI`; tests script it with a fake.
public protocol AgentRelayBackendAPI: Sendable {
    func mint(provider: ExternalAgentProvider) async throws -> AgentRelayMint
    func fetch(requestId: String, waitMs: Int) async throws -> AgentRelayFetchOutcome
    func ack(requestId: String) async throws
    func listCompleted() async throws -> [AgentRelayCompletedEntry]
}

/// `AgentRelayBackendAPI` over `ConvosAPIClientProtocol.authorizedRequest`,
/// executed on a dedicated session so long-poll responses never pass
/// through the client's body-logging path.
public final class AgentRelayHTTPAPI: AgentRelayBackendAPI {
    private let apiClient: any ConvosAPIClientProtocol
    let session: URLSession

    public init(apiClient: any ConvosAPIClientProtocol) {
        let configuration = URLSessionConfiguration.default
        configuration.timeoutIntervalForRequest = Constant.requestTimeout
        self.apiClient = apiClient
        session = URLSession(configuration: configuration)
    }

    init(apiClient: any ConvosAPIClientProtocol, configuration: URLSessionConfiguration) {
        configuration.timeoutIntervalForRequest = Constant.requestTimeout
        self.apiClient = apiClient
        session = URLSession(configuration: configuration)
    }

    public func mint(provider: ExternalAgentProvider) async throws -> AgentRelayMint {
        var request = try await authorizedRequest(endpoint: Constant.requestsEndpoint, method: "POST")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(MintBody(provider: provider))

        let (data, response) = try await execute(request)
        guard response.statusCode == 201 else {
            throw AgentRelayError.relayRejected(response.statusCode)
        }
        return try decode(AgentRelayMint.self, from: data)
    }

    public func fetch(requestId: String, waitMs: Int) async throws -> AgentRelayFetchOutcome {
        let endpoint = "\(Constant.requestsEndpoint)/\(requestId)"
        let query = ["wait_ms": String(waitMs)]
        let request = try await authorizedRequest(endpoint: endpoint, method: "GET", queryParameters: query)
        let (data, response) = try await execute(request)

        switch response.statusCode {
        case 200:
            let wire = try decode(CompletedResponse.self, from: data)
            return .completed(wire.result)
        case 202:
            let wire = try decode(PendingResponse.self, from: data)
            return .pending(expiresAt: wire.expiresAt)
        case 410:
            return .expired
        case 404:
            return .notFound
        default:
            throw AgentRelayError.relayRejected(response.statusCode)
        }
    }

    public func ack(requestId: String) async throws {
        let endpoint = "\(Constant.requestsEndpoint)/\(requestId)/ack"
        let request = try await authorizedRequest(endpoint: endpoint, method: "POST")
        let (_, response) = try await execute(request)
        guard response.statusCode == 204 || response.statusCode == 404 else {
            throw AgentRelayError.relayRejected(response.statusCode)
        }
    }

    public func listCompleted() async throws -> [AgentRelayCompletedEntry] {
        let query = ["status": "completed"]
        let request = try await authorizedRequest(endpoint: Constant.requestsEndpoint, method: "GET", queryParameters: query)
        let (data, response) = try await execute(request)
        guard response.statusCode == 200 else {
            throw AgentRelayError.relayRejected(response.statusCode)
        }

        let listing = try decode(CompletedListing.self, from: data)
        return listing.requests.map { entry in
            let result = AgentRelayTurnResult(
                message: entry.result.message,
                links: entry.result.links,
                completedAt: entry.completedAt
            )
            return AgentRelayCompletedEntry(requestId: entry.requestId, provider: entry.provider, result: result)
        }
    }

    private func authorizedRequest(
        endpoint: String,
        method: String,
        queryParameters: [String: String]? = nil
    ) async throws -> URLRequest {
        do {
            return try await apiClient.authorizedRequest(
                for: endpoint,
                method: method,
                queryParameters: queryParameters
            )
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw AgentRelayError.relayUnreachable
        }
    }

    private func execute(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        do {
            let (data, response) = try await session.data(for: request)
            guard let httpResponse = response as? HTTPURLResponse else {
                throw AgentRelayError.relayUnreachable
            }
            return (data, httpResponse)
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as AgentRelayError {
            throw error
        } catch {
            guard !Task.isCancelled else { throw CancellationError() }
            throw AgentRelayError.relayUnreachable
        }
    }

    private func decode<Value: Decodable>(_ type: Value.Type, from data: Data) throws -> Value {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        do {
            return try decoder.decode(type, from: data)
        } catch {
            throw AgentRelayError.unreadableResult
        }
    }

    private struct MintBody: Encodable {
        let provider: ExternalAgentProvider
    }

    private struct CompletedResponse: Decodable {
        let result: AgentRelayTurnResult
    }

    private struct PendingResponse: Decodable {
        let expiresAt: Date
    }

    private struct CompletedListing: Decodable {
        let requests: [CompletedEntry]
    }

    private struct CompletedEntry: Decodable {
        let requestId: String
        let provider: ExternalAgentProvider?
        let completedAt: Date
        let result: ListedResult
    }

    private struct ListedResult: Decodable {
        let message: String
        let links: [AgentRelayLink]
    }

    private enum Constant {
        static let requestTimeout: TimeInterval = 35
        static let requestsEndpoint: String = "v2/agent-relay/requests"
    }
}
