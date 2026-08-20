@testable import ConvosCore
import Foundation

enum AgentRelayTestError: Error {
    case expected
}

final class AgentRelayCallRecorder: @unchecked Sendable {
    private let lock: NSLock = NSLock()
    private var storedCalls: [String] = []

    var calls: [String] {
        lock.withLock { storedCalls }
    }

    func append(_ call: String) {
        lock.withLock {
            storedCalls.append(call)
        }
    }
}

final class ScriptedAgentRelayAPI: AgentRelayBackendAPI, @unchecked Sendable {
    private struct State {
        var fetchOutcomes: [AgentRelayFetchOutcome]
        var fetchCount: Int = 0
        var ackCount: Int = 0
        var ackFailuresRemaining: Int
        var blocksFetch: Bool
    }

    private let lock: NSLock = NSLock()
    private var state: State
    private let mintValue: AgentRelayMint
    private let completedEntries: [AgentRelayCompletedEntry]
    private let recorder: AgentRelayCallRecorder?

    init(
        mint: AgentRelayMint = makeAgentRelayMint(),
        fetchOutcomes: [AgentRelayFetchOutcome] = [],
        completedEntries: [AgentRelayCompletedEntry] = [],
        ackFailuresRemaining: Int = 0,
        blocksFetch: Bool = false,
        recorder: AgentRelayCallRecorder? = nil
    ) {
        mintValue = mint
        self.completedEntries = completedEntries
        self.recorder = recorder
        state = State(
            fetchOutcomes: fetchOutcomes,
            ackFailuresRemaining: ackFailuresRemaining,
            blocksFetch: blocksFetch
        )
    }

    var fetchCount: Int {
        lock.withLock { state.fetchCount }
    }

    var ackCount: Int {
        lock.withLock { state.ackCount }
    }

    func mint(provider: ExternalAgentProvider) async throws -> AgentRelayMint {
        recorder?.append("mint")
        return mintValue
    }

    func fetch(requestId: String, waitMs: Int) async throws -> AgentRelayFetchOutcome {
        let blocksFetch = lock.withLock { () -> Bool in
            state.fetchCount += 1
            return state.blocksFetch
        }
        recorder?.append("fetch")
        if blocksFetch {
            try await Task.sleep(nanoseconds: 60_000_000_000)
        }
        return lock.withLock {
            guard !state.fetchOutcomes.isEmpty else { return .notFound }
            return state.fetchOutcomes.removeFirst()
        }
    }

    func ack(requestId: String) async throws {
        let shouldFail = lock.withLock { () -> Bool in
            state.ackCount += 1
            guard state.ackFailuresRemaining > 0 else { return false }
            state.ackFailuresRemaining -= 1
            return true
        }
        recorder?.append("ack")
        if shouldFail {
            throw AgentRelayTestError.expected
        }
    }

    func listCompleted() async throws -> [AgentRelayCompletedEntry] {
        recorder?.append("listCompleted")
        return completedEntries
    }
}

final class ScriptedWebhookTransport: AgentWebhookTransport, @unchecked Sendable {
    private let lock: NSLock = NSLock()
    private let error: Error?
    private let recorder: AgentRelayCallRecorder?
    private var storedPayloads: [AgentWebhookPayload] = []

    init(error: Error? = nil, recorder: AgentRelayCallRecorder? = nil) {
        self.error = error
        self.recorder = recorder
    }

    var payloads: [AgentWebhookPayload] {
        lock.withLock { storedPayloads }
    }

    func trigger(payload: AgentWebhookPayload, url: URL, auth: AgentWebhookAuth) async throws {
        lock.withLock {
            storedPayloads.append(payload)
        }
        recorder?.append("webhook")
        if let error {
            throw error
        }
    }
}

final class RecordingAgentChatWriter: AgentChatWriterProtocol, @unchecked Sendable {
    private let recorder: AgentRelayCallRecorder

    init(recorder: AgentRelayCallRecorder) {
        self.recorder = recorder
    }

    func insertPending(_ turn: AgentTurn) throws {
        recorder.append("pending")
    }

    func markCompleted(requestId: String, result: AgentRelayTurnResult, provider: ExternalAgentProvider) throws {
        recorder.append("completed")
    }

    func markFailed(requestId: String, errorCode: String) throws {
        recorder.append("failed")
    }

    func markExpired(requestId: String) throws {
        recorder.append("expired")
    }

    func markCollectedElsewhere(requestId: String) throws {
        recorder.append("collectedElsewhere")
    }

    func markAcked(requestId: String) throws {
        recorder.append("acked")
    }

    func deleteAll() throws {
        recorder.append("deleteAll")
    }
}

struct StubAgentHistoryBuilder: AgentHistoryBuilding {
    let entries: [AgentWebhookHistoryEntry]

    init(entries: [AgentWebhookHistoryEntry] = []) {
        self.entries = entries
    }

    func history(excluding requestId: String?) throws -> [AgentWebhookHistoryEntry] {
        entries
    }
}

final class InMemoryAgentRelayKeychain: KeychainServiceProtocol, @unchecked Sendable {
    private let lock: NSLock = NSLock()
    private var storage: [String: Data] = [:]

    func saveString(_ value: String, account: String) throws {
        guard let data = value.data(using: .utf8) else { throw AgentRelayTestError.expected }
        try saveData(data, account: account)
    }

    func saveData(_ data: Data, account: String) throws {
        lock.withLock {
            storage[account] = data
        }
    }

    func retrieveString(account: String) throws -> String? {
        guard let data = try retrieveData(account: account) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    func retrieveData(account: String) throws -> Data? {
        lock.withLock { storage[account] }
    }

    func delete(account: String) throws {
        lock.withLock {
            _ = storage.removeValue(forKey: account)
        }
    }
}

func makeAgentRelayMint(requestId: String = "request_test") -> AgentRelayMint {
    AgentRelayMint(
        requestId: requestId,
        returnToken: "return_fake_token",
        mcpUrl: URL(string: "https://api.example.com/api/v2/agent-relay/mcp") ?? URL(fileURLWithPath: "/mcp"),
        expiresAt: Date().addingTimeInterval(3_600)
    )
}

func makeAgentRelayResult(message: String = "Done", completedAt: Date = Date()) -> AgentRelayTurnResult {
    AgentRelayTurnResult(
        message: message,
        links: [AgentRelayLink(title: "Example", url: URL(string: "https://example.com") ?? URL(fileURLWithPath: "/"))],
        completedAt: completedAt
    )
}

func makeAgentTurn(
    requestId: String,
    status: AgentTurnStatus = .pending,
    prompt: String = "Prompt",
    createdAt: Date = Date(),
    expiresAt: Date? = nil,
    resultMessage: String? = nil,
    completedAt: Date? = nil,
    ackedAt: Date? = nil
) -> AgentTurn {
    AgentTurn(
        requestId: requestId,
        provider: .town,
        status: status,
        prompt: prompt,
        resultMessage: resultMessage,
        createdAt: createdAt,
        expiresAt: expiresAt ?? createdAt.addingTimeInterval(3_600),
        completedAt: completedAt,
        ackedAt: ackedAt
    )
}

func makeAgentConnection(provider: ExternalAgentProvider = .town) -> AgentConnection {
    let url = URL(string: "https://hooks.example.com/webhook") ?? URL(fileURLWithPath: "/webhook")
    switch provider {
    case .town:
        return AgentConnection(provider: .town, webhookURL: url, auth: .bearer(secret: "bearer-secret"))
    case .tasklet:
        return AgentConnection(provider: .tasklet, webhookURL: url, auth: .capabilityURL)
    }
}

func makeConfiguredEnvironment(local: Bool, suiteName: String = "group.agent-relay-tests") -> AppEnvironment {
    let configuration = ConvosConfiguration(
        apiBaseURL: "https://api.example.com/api",
        appGroupIdentifier: suiteName,
        relyingPartyIdentifier: "example.com",
        siweConfiguration: SIWEConfiguration(domain: "example.com", uri: "https://example.com", chainId: 1)
    )
    if local {
        return .local(config: configuration)
    }
    return .dev(config: configuration)
}
