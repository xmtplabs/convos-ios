import ConvosCore
import Foundation
import XCTest
@testable import Convos

@MainActor
final class AgentChatViewModelTests: XCTestCase {
    func testInitialTextPrefillsComposerExactly() throws {
        let fixture = try AgentChatViewModelFixture()
        let draft = AgentChatDraft(
            provider: .tasklet,
            text: "Please summarize this message exactly as written."
        )

        let viewModel = fixture.makeViewModel(provider: draft.provider, initialText: draft.text)

        XCTAssertEqual(viewModel.composerText, draft.text)
    }

    /// Sending supersedes an in-flight turn instead of waiting for it, so a
    /// pending turn never disables the composer - only empty text does.
    func testCanSubmitIsNotBlockedByAPendingTurn() throws {
        let fixture = try AgentChatViewModelFixture()
        let viewModel = fixture.makeViewModel(provider: .town, initialText: "Next request")

        XCTAssertTrue(viewModel.canSubmit)

        viewModel.turns = [makeAgentChatTurn(
            status: .pending,
            createdAt: Date().addingTimeInterval(-60)
        )]
        XCTAssertTrue(viewModel.canSubmit)

        viewModel.composerText = "   "
        XCTAssertFalse(viewModel.canSubmit)
    }

    func testSubmitSupersedesTheInFlightTurn() async throws {
        let fixture = try AgentChatViewModelFixture()
        let inFlight = makeAgentChatTurn(
            requestId: "request_in_flight",
            provider: .town,
            status: .pending,
            createdAt: Date().addingTimeInterval(-30)
        )
        try fixture.insertPending(inFlight)
        let viewModel = fixture.makeViewModel(provider: .town, initialText: "A newer request")

        viewModel.submit()

        let status: AgentTurnStatus? = try fixture.repository.turn(requestId: inFlight.requestId)?.status
        XCTAssertEqual(status, .superseded)
    }

    func testCheckAgainCollectsThenRearmsWatch() async throws {
        let completedResult = AgentRelayTurnResult(
            message: "Completed after checking again",
            links: [],
            completedAt: Date()
        )
        let fixture = try AgentChatViewModelFixture(fetchOutcomes: [
            .pending(expiresAt: Date().addingTimeInterval(3_600)),
            .completed(completedResult),
        ])
        let pendingTurn = makeAgentChatTurn(
            requestId: "request_check_again",
            provider: .town,
            status: .pending,
            createdAt: Date().addingTimeInterval(-601)
        )
        try fixture.insertPending(pendingTurn)
        let viewModel = fixture.makeViewModel(provider: .town)

        viewModel.checkAgain(turn: pendingTurn)
        while await fixture.api.ackCount == 0 {
            try await Task.sleep(nanoseconds: 1_000_000)
        }

        let turn = try fixture.repository.turn(requestId: pendingTurn.requestId)
        let ackCount: Int = await fixture.api.ackCount
        XCTAssertEqual(turn?.status, .completed)
        XCTAssertEqual(turn?.resultMessage, completedResult.message)
        XCTAssertNotNil(turn?.ackedAt)
        XCTAssertEqual(ackCount, 1)
    }

    func testAgentRelayPreviewBuildUsesPRBundleSuffix() {
        XCTAssertTrue(ConfigManager.isAgentRelayPreviewBundleIdentifier("org.convos.ios-preview.pr"))
        XCTAssertFalse(ConfigManager.isAgentRelayPreviewBundleIdentifier("org.convos.ios-preview"))
        XCTAssertFalse(ConfigManager.isAgentRelayPreviewBundleIdentifier("org.convos.ios-production"))
    }

    func testRetrySubmitsANewTurnWithTheFailedPrompt() async throws {
        let fixture = try AgentChatViewModelFixture()
        let viewModel = fixture.makeViewModel(provider: .tasklet)
        let failedTurn = makeAgentChatTurn(
            requestId: "request_failed_original",
            provider: .tasklet,
            status: .failed,
            prompt: "Retry this prompt"
        )

        viewModel.retry(turn: failedTurn)
        while await fixture.api.ackCount == 0 {
            try await Task.sleep(nanoseconds: 1_000_000)
        }

        let turns = try fixture.repository.turns(limit: 10)
        let prompts = await fixture.webhook.recordedPrompts()
        XCTAssertEqual(prompts, [failedTurn.prompt])
        XCTAssertEqual(turns.count, 1)
        XCTAssertEqual(turns.first?.requestId, "request_view_model_1")
        XCTAssertNotEqual(turns.first?.requestId, failedTurn.requestId)
        XCTAssertEqual(turns.first?.prompt, failedTurn.prompt)
    }
}

@MainActor
private final class AgentChatViewModelFixture {
    let repository: AgentChatRepository
    let api: RecordingAgentRelayBackendAPI
    let webhook: RecordingAgentWebhookTransport

    private let dependencies: AgentRelayDependencies
    private let defaultsSuiteName: String

    init(fetchOutcomes: [AgentRelayFetchOutcome] = []) throws {
        let database = try AgentChatDatabase.inMemoryForTests()
        let writer = AgentChatWriter(database: database)
        let repository = AgentChatRepository(database: database)
        let api = RecordingAgentRelayBackendAPI(fetchOutcomes: fetchOutcomes)
        let webhook = RecordingAgentWebhookTransport()
        let client = AgentRelayClient(
            api: api,
            webhook: webhook,
            store: writer,
            history: EmptyAgentHistoryBuilder()
        )
        let defaultsSuiteName = "group.agent-chat-view-model-tests.\(UUID().uuidString)"
        let configuration = ConvosConfiguration(
            apiBaseURL: "https://api.example.com/api",
            appGroupIdentifier: defaultsSuiteName,
            relyingPartyIdentifier: "example.com",
            siweConfiguration: SIWEConfiguration(
                domain: "example.com",
                uri: "https://example.com",
                chainId: 1
            )
        )
        let environment = AppEnvironment.dev(config: configuration)
        let connectionStore = AgentConnectionStore(
            environment: environment,
            keychain: AgentChatViewModelKeychain()
        )
        let webhookURL = try XCTUnwrap(URL(string: "https://hooks.example.com/tasklet"))
        try connectionStore.save(AgentConnection(
            provider: .tasklet,
            webhookURL: webhookURL,
            auth: .capabilityURL
        ))
        let mcpURL = try XCTUnwrap(URL(string: "https://api.example.com/api/v2/agent-relay/mcp"))

        self.repository = repository
        self.api = api
        self.webhook = webhook
        self.defaultsSuiteName = defaultsSuiteName
        self.dependencies = AgentRelayDependencies(
            database: database,
            connectionStore: connectionStore,
            client: client,
            mcpURL: mcpURL
        )
    }

    deinit {
        UserDefaults.standard.removePersistentDomain(forName: defaultsSuiteName)
    }

    func makeViewModel(
        provider: ExternalAgentProvider,
        initialText: String = ""
    ) -> AgentChatViewModel {
        AgentChatViewModel(
            provider: provider,
            dependencies: dependencies,
            initialText: initialText
        )
    }

    func insertPending(_ turn: AgentTurn) throws {
        try dependencies.writer.insertPending(turn)
    }
}

private actor RecordingAgentRelayBackendAPI: AgentRelayBackendAPI {
    private var mintCount: Int = 0
    private(set) var ackCount: Int = 0
    private var fetchOutcomes: [AgentRelayFetchOutcome]

    init(fetchOutcomes: [AgentRelayFetchOutcome] = []) {
        self.fetchOutcomes = fetchOutcomes
    }

    func mint(provider: ExternalAgentProvider) async throws -> AgentRelayMint {
        mintCount += 1
        let mcpURL = URL(string: "https://api.example.com/api/v2/agent-relay/mcp")
            ?? URL(fileURLWithPath: "/mcp")
        return AgentRelayMint(
            requestId: "request_view_model_\(mintCount)",
            returnToken: "return_view_model",
            mcpUrl: mcpURL,
            expiresAt: Date().addingTimeInterval(3_600)
        )
    }

    func fetch(requestId: String, waitMs: Int) async throws -> AgentRelayFetchOutcome {
        guard !fetchOutcomes.isEmpty else {
            return .completed(AgentRelayTurnResult(
                message: "Completed",
                links: [],
                completedAt: Date()
            ))
        }
        return fetchOutcomes.removeFirst()
    }

    func ack(requestId: String) async throws {
        ackCount += 1
    }

    func listCompleted() async throws -> [AgentRelayCompletedEntry] {
        []
    }
}

private actor RecordingAgentWebhookTransport: AgentWebhookTransport {
    private var prompts: [String] = []

    func trigger(payload: AgentWebhookPayload, url: URL, auth: AgentWebhookAuth) async throws {
        prompts.append(payload.prompt)
    }

    func recordedPrompts() -> [String] {
        prompts
    }
}

private struct EmptyAgentHistoryBuilder: AgentHistoryBuilding {
    func history(excluding requestId: String?) throws -> [AgentWebhookHistoryEntry] {
        []
    }
}

private final class AgentChatViewModelKeychain: KeychainServiceProtocol, @unchecked Sendable {
    private let lock: NSLock = NSLock()
    private var storage: [String: Data] = [:]

    func saveString(_ value: String, account: String) throws {
        guard let data = value.data(using: .utf8) else { return }
        try saveData(data, account: account)
    }

    func saveData(_ data: Data, account: String) throws {
        lock.lock()
        storage[account] = data
        lock.unlock()
    }

    func retrieveString(account: String) throws -> String? {
        guard let data = try retrieveData(account: account) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    func retrieveData(account: String) throws -> Data? {
        lock.lock()
        let data = storage[account]
        lock.unlock()
        return data
    }

    func delete(account: String) throws {
        lock.lock()
        storage.removeValue(forKey: account)
        lock.unlock()
    }
}

private func makeAgentChatTurn(
    requestId: String = "request_existing",
    provider: ExternalAgentProvider = .town,
    status: AgentTurnStatus,
    prompt: String = "Existing prompt",
    createdAt: Date = Date()
) -> AgentTurn {
    return AgentTurn(
        requestId: requestId,
        provider: provider,
        status: status,
        prompt: prompt,
        createdAt: createdAt,
        expiresAt: createdAt.addingTimeInterval(3_600)
    )
}
