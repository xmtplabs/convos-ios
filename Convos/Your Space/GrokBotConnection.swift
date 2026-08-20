import ConvosCore
import Foundation
import Security

struct GrokBotAgent: Codable, Equatable, Hashable, Identifiable, Sendable {
    let id: String
    let name: String
    let title: String?
    let description: String?

    var harnessName: String {
        "Grok Bot · \(name)"
    }

    var detail: String? {
        let values = [title, description]
            .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        return values.isEmpty ? nil : values.joined(separator: " · ")
    }
}

struct GrokBotConnectionConfiguration: Equatable, Sendable {
    static let defaultBridgeURL: URL = TownConnectionConfiguration.defaultBridgeURL

    let sessionId: String
    let sessionToken: String
    let bridgeURL: URL
    let sharesYourSpaceContext: Bool
    let agents: [GrokBotAgent]
    let enabledAgentIds: Set<String>

    init(
        sessionId: String,
        sessionToken: String,
        bridgeURLText: String = Self.defaultBridgeURL.absoluteString,
        sharesYourSpaceContext: Bool,
        agents: [GrokBotAgent] = [],
        enabledAgentIds: Set<String> = []
    ) throws {
        let trimmedSessionId = sessionId.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedSessionToken = sessionToken.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedSessionId.isEmpty, !trimmedSessionToken.isEmpty else {
            throw GrokBotConnectionError.invalidSession
        }

        self.sessionId = trimmedSessionId
        self.sessionToken = trimmedSessionToken
        bridgeURL = try Self.bridgeURL(from: bridgeURLText)
        self.sharesYourSpaceContext = sharesYourSpaceContext
        self.agents = agents
        self.enabledAgentIds = enabledAgentIds.intersection(Set(agents.map(\.id)))
    }

    fileprivate init(
        sessionId: String,
        sessionToken: String,
        bridgeURL: URL,
        sharesYourSpaceContext: Bool,
        agents: [GrokBotAgent],
        enabledAgentIds: Set<String>
    ) {
        self.sessionId = sessionId
        self.sessionToken = sessionToken
        self.bridgeURL = bridgeURL
        self.sharesYourSpaceContext = sharesYourSpaceContext
        self.agents = agents
        self.enabledAgentIds = enabledAgentIds.intersection(Set(agents.map(\.id)))
    }

    var enabledAgents: [GrokBotAgent] {
        agents.filter { enabledAgentIds.contains($0.id) }
    }

    func updating(
        agents: [GrokBotAgent]? = nil,
        enabledAgentIds: Set<String>? = nil,
        sharesYourSpaceContext: Bool? = nil,
        bridgeURLText: String? = nil
    ) throws -> GrokBotConnectionConfiguration {
        try GrokBotConnectionConfiguration(
            sessionId: sessionId,
            sessionToken: sessionToken,
            bridgeURLText: bridgeURLText ?? bridgeURL.absoluteString,
            sharesYourSpaceContext: sharesYourSpaceContext ?? self.sharesYourSpaceContext,
            agents: agents ?? self.agents,
            enabledAgentIds: enabledAgentIds ?? self.enabledAgentIds
        )
    }

    private static func bridgeURL(from text: String) throws -> URL {
        let trimmedBridge = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let bridgeURL = URL(string: trimmedBridge),
              bridgeURL.scheme?.lowercased() == "https",
              bridgeURL.host != nil,
              bridgeURL.query == nil,
              bridgeURL.fragment == nil else {
            throw GrokBotConnectionError.invalidBridgeURL
        }
        return bridgeURL
    }
}

enum GrokBotConnectionStore {
    private struct PersistedConfiguration: Codable {
        let sessionId: String
        let bridgeURL: URL
        let sharesYourSpaceContext: Bool
        let agents: [GrokBotAgent]
        let enabledAgentIds: Set<String>
    }

    private static let configurationKey: String = "your-space-grokbot-connection-v1"
    private static let tokenAccount: String = "your-space-grokbot-session-token-v1"

    static func configuration(
        defaults: UserDefaults = .standard,
        keychain: any KeychainServiceProtocol = KeychainService()
    ) -> GrokBotConnectionConfiguration? {
        guard let data = defaults.data(forKey: configurationKey),
              let persisted = try? JSONDecoder().decode(PersistedConfiguration.self, from: data),
              let sessionToken = try? keychain.retrieveString(account: tokenAccount),
              !sessionToken.isEmpty else {
            return nil
        }
        return GrokBotConnectionConfiguration(
            sessionId: persisted.sessionId,
            sessionToken: sessionToken,
            bridgeURL: persisted.bridgeURL,
            sharesYourSpaceContext: persisted.sharesYourSpaceContext,
            agents: persisted.agents,
            enabledAgentIds: persisted.enabledAgentIds
        )
    }

    static func save(
        _ configuration: GrokBotConnectionConfiguration,
        defaults: UserDefaults = .standard,
        keychain: any KeychainServiceProtocol = KeychainService()
    ) throws {
        let persisted = PersistedConfiguration(
            sessionId: configuration.sessionId,
            bridgeURL: configuration.bridgeURL,
            sharesYourSpaceContext: configuration.sharesYourSpaceContext,
            agents: configuration.agents,
            enabledAgentIds: configuration.enabledAgentIds
        )
        try keychain.saveString(configuration.sessionToken, account: tokenAccount)
        defaults.set(try JSONEncoder().encode(persisted), forKey: configurationKey)
    }

    static func disconnect(
        defaults: UserDefaults = .standard,
        keychain: any KeychainServiceProtocol = KeychainService()
    ) throws {
        defaults.removeObject(forKey: configurationKey)
        try keychain.delete(account: tokenAccount)
    }
}

typealias GrokBotYourSpaceSnapshot = TownYourSpaceSnapshot
typealias GrokBotTurnResult = TownTurnResult

final class GrokBotBridgeClient: Sendable {
    enum AgentList: Equatable, Sendable {
        case waitingForComputer
        case available([GrokBotAgent])
    }

    private let session: URLSession

    init(session: URLSession = .shared) {
        self.session = session
    }

    func createSession(
        bridgeURLText: String = GrokBotConnectionConfiguration.defaultBridgeURL.absoluteString,
        sharesYourSpaceContext: Bool
    ) async throws -> GrokBotConnectionConfiguration {
        let placeholder = try GrokBotConnectionConfiguration(
            sessionId: "pending",
            sessionToken: "pending",
            bridgeURLText: bridgeURLText,
            sharesYourSpaceContext: sharesYourSpaceContext
        )
        var request = URLRequest(url: placeholder.bridgeURL.appendingPathComponent("v1/grokbot/sessions"))
        request.httpMethod = "POST"
        request.timeoutInterval = 20
        request.cachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 201 else {
            throw GrokBotConnectionError.bridgeRejected((response as? HTTPURLResponse)?.statusCode ?? 0)
        }
        let created = try JSONDecoder().decode(SessionResponse.self, from: data)
        return try GrokBotConnectionConfiguration(
            sessionId: created.sessionId,
            sessionToken: created.sessionToken,
            bridgeURLText: bridgeURLText,
            sharesYourSpaceContext: sharesYourSpaceContext
        )
    }

    func fetchAgents(configuration: GrokBotConnectionConfiguration) async throws -> AgentList {
        var components = URLComponents(
            url: configuration.bridgeURL.appendingPathComponent("v1/grokbot/agents"),
            resolvingAgainstBaseURL: false
        )
        components?.queryItems = [URLQueryItem(name: "token", value: configuration.sessionToken)]
        guard let url = components?.url else { throw GrokBotConnectionError.invalidBridgeURL }
        var request = URLRequest(url: url)
        request.timeoutInterval = 25
        request.cachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw GrokBotConnectionError.invalidBridgeResponse
        }
        if http.statusCode == 202 {
            return .waitingForComputer
        }
        guard http.statusCode == 200 else {
            throw GrokBotConnectionError.bridgeRejected(http.statusCode)
        }
        return .available(try JSONDecoder().decode(AgentsResponse.self, from: data).agents)
    }

    func send(
        _ prompt: String,
        to agent: GrokBotAgent,
        configuration: GrokBotConnectionConfiguration,
        yourSpaceSnapshot: GrokBotYourSpaceSnapshot?
    ) async throws -> GrokBotTurnResult {
        guard configuration.enabledAgentIds.contains(agent.id) else {
            throw GrokBotConnectionError.agentNotEnabled
        }
        let requestId = try Self.capability(prefix: "request_", byteCount: 24)
        let returnToken = try Self.capability(prefix: "return_", byteCount: 36)
        try await register(requestId: requestId, returnToken: returnToken, configuration: configuration)
        try await enqueue(
            prompt: prompt,
            agent: agent,
            requestId: requestId,
            returnToken: returnToken,
            configuration: configuration,
            yourSpaceSnapshot: configuration.sharesYourSpaceContext ? yourSpaceSnapshot : nil
        )
        return try await poll(requestId: requestId, returnToken: returnToken, configuration: configuration)
    }

    private func register(
        requestId: String,
        returnToken: String,
        configuration: GrokBotConnectionConfiguration
    ) async throws {
        var request = URLRequest(url: configuration.bridgeURL.appendingPathComponent("v1/requests"))
        request.httpMethod = "POST"
        request.timeoutInterval = 20
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(RegisterRequest(requestId: requestId, returnToken: returnToken))
        let (_, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 201 else {
            throw GrokBotConnectionError.bridgeRejected((response as? HTTPURLResponse)?.statusCode ?? 0)
        }
    }

    private func enqueue(
        prompt: String,
        agent: GrokBotAgent,
        requestId: String,
        returnToken: String,
        configuration: GrokBotConnectionConfiguration,
        yourSpaceSnapshot: GrokBotYourSpaceSnapshot?
    ) async throws {
        let payload = EnqueueRequest(
            sessionToken: configuration.sessionToken,
            agentId: agent.id,
            requestId: requestId,
            returnToken: returnToken,
            prompt: prompt,
            homeContext: yourSpaceSnapshot
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        var request = URLRequest(url: configuration.bridgeURL.appendingPathComponent("v1/grokbot/enqueue"))
        request.httpMethod = "POST"
        request.timeoutInterval = 30
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try encoder.encode(payload)
        let (_, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 202 else {
            throw GrokBotConnectionError.bridgeRejected((response as? HTTPURLResponse)?.statusCode ?? 0)
        }
    }

    private func poll(
        requestId: String,
        returnToken: String,
        configuration: GrokBotConnectionConfiguration
    ) async throws -> GrokBotTurnResult {
        let deadline = Date().addingTimeInterval(10 * 60)
        while Date() < deadline {
            try Task.checkCancellation()
            var components = URLComponents(
                url: configuration.bridgeURL.appendingPathComponent("v1/requests/\(requestId)"),
                resolvingAgainstBaseURL: false
            )
            components?.queryItems = [URLQueryItem(name: "token", value: returnToken)]
            guard let url = components?.url else { throw GrokBotConnectionError.invalidBridgeURL }
            var request = URLRequest(url: url)
            request.timeoutInterval = 20
            request.cachePolicy = .reloadIgnoringLocalAndRemoteCacheData
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse else {
                throw GrokBotConnectionError.invalidBridgeResponse
            }
            if http.statusCode == 200 {
                guard let result = try JSONDecoder().decode(PollResponse.self, from: data).result else {
                    throw GrokBotConnectionError.invalidBridgeResponse
                }
                return GrokBotTurnResult(message: result.message, links: result.links)
            }
            if http.statusCode == 410 {
                throw GrokBotConnectionError.requestExpired
            }
            guard http.statusCode == 202 else {
                throw GrokBotConnectionError.bridgeRejected(http.statusCode)
            }
            try await Task.sleep(for: .seconds(2))
        }
        throw GrokBotConnectionError.timedOut
    }

    private static func capability(prefix: String, byteCount: Int) throws -> String {
        var bytes = [UInt8](repeating: 0, count: byteCount)
        guard SecRandomCopyBytes(kSecRandomDefault, byteCount, &bytes) == errSecSuccess else {
            throw GrokBotConnectionError.couldNotCreateCapability
        }
        let value = Data(bytes)
            .base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
        return prefix + value
    }

    private struct SessionResponse: Decodable {
        let sessionId: String
        let sessionToken: String
    }

    private struct AgentsResponse: Decodable {
        let agents: [GrokBotAgent]
    }

    private struct RegisterRequest: Encodable {
        let requestId: String
        let returnToken: String
    }

    private struct EnqueueRequest: Encodable {
        let sessionToken: String
        let agentId: String
        let requestId: String
        let returnToken: String
        let prompt: String
        let homeContext: GrokBotYourSpaceSnapshot?

        enum CodingKeys: String, CodingKey {
            case sessionToken
            case agentId
            case requestId
            case returnToken
            case prompt
            case homeContext = "home_context"
        }
    }

    private struct PollResponse: Decodable {
        struct Result: Decodable {
            let message: String
            let links: [GrokBotTurnResult.Link]
        }

        let result: Result?
    }
}

enum GrokBotConnectionError: LocalizedError, Equatable {
    case invalidSession
    case invalidBridgeURL
    case bridgeRejected(Int)
    case invalidBridgeResponse
    case requestExpired
    case timedOut
    case couldNotCreateCapability
    case agentNotEnabled
    case notConnected

    var errorDescription: String? {
        switch self {
        case .invalidSession:
            "Create a new Grok Bot connection and try again."
        case .invalidBridgeURL:
            "The Grok Bot bridge must be a valid HTTPS URL."
        case .bridgeRejected(let status):
            "The Grok Bot bridge rejected the request (\(status))."
        case .invalidBridgeResponse:
            "Grok Bot returned an unreadable response. Try again."
        case .requestExpired:
            "That Grok Bot request expired. Send it again."
        case .timedOut:
            "Grok Bot is still working after ten minutes. Check the agent on your computer, then try again."
        case .couldNotCreateCapability:
            "Convos couldn't secure this request. Try again."
        case .agentNotEnabled:
            "Enable this Grok Bot in the connection picker before sending a message."
        case .notConnected:
            "Connect Grok Bot and choose at least one agent before sending a message."
        }
    }
}
