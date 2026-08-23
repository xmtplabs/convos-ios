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
            provider: .tasklet,
            status: .pending,
            createdAt: Date().addingTimeInterval(-30)
        )
        try fixture.insertPending(inFlight)
        let viewModel = fixture.makeViewModel(provider: .tasklet, initialText: "A newer request")

        viewModel.submit()

        let deadline = Date().addingTimeInterval(1)
        var status: AgentTurnStatus? = try fixture.repository.turn(requestId: inFlight.requestId)?.status
        while status == .pending, Date() < deadline {
            try await Task.sleep(nanoseconds: 1_000_000)
            status = try fixture.repository.turn(requestId: inFlight.requestId)?.status
        }
        XCTAssertEqual(status, .superseded)
    }

    func testSubmitWithoutConnectionPreservesComposerAndPendingTurn() async throws {
        let fixture = try AgentChatViewModelFixture(installDefaultConnection: false)
        let inFlight = makeAgentChatTurn(
            requestId: "request_without_connection",
            provider: .tasklet,
            status: .pending
        )
        try fixture.insertPending(inFlight)
        let draftText = "Keep this draft"
        let viewModel = fixture.makeViewModel(provider: .tasklet, initialText: draftText)

        viewModel.submit()
        let deadline = Date().addingTimeInterval(1)
        while viewModel.errorMessage == nil, Date() < deadline {
            try await Task.sleep(nanoseconds: 1_000_000)
        }

        let status: AgentTurnStatus? = try fixture.repository.turn(requestId: inFlight.requestId)?.status
        XCTAssertEqual(viewModel.composerText, draftText)
        XCTAssertEqual(status, .pending)
        XCTAssertNotNil(viewModel.errorMessage)
    }

    func testComposerPreservesTextTypedWhileSessionBecomesReady() async throws {
        let fixture = try AgentChatViewModelFixture()
        let waitUntilReadyGate = AgentChatWaitUntilReadyGate()
        let inFlight = makeAgentChatTurn(
            requestId: "request_while_session_becomes_ready",
            provider: .tasklet,
            status: .pending
        )
        try fixture.insertPending(inFlight)
        let viewModel = fixture.makeViewModel(
            provider: .tasklet,
            initialText: "a",
            waitUntilReady: { await waitUntilReadyGate.wait() }
        )

        viewModel.submit()
        let entryDeadline = Date().addingTimeInterval(1)
        var didEnterWaitUntilReady = await waitUntilReadyGate.hasEntered
        while !didEnterWaitUntilReady, Date() < entryDeadline {
            try await Task.sleep(nanoseconds: 1_000_000)
            didEnterWaitUntilReady = await waitUntilReadyGate.hasEntered
        }
        XCTAssertTrue(didEnterWaitUntilReady)

        viewModel.composerText = "ab"
        await waitUntilReadyGate.release()

        let sendDeadline = Date().addingTimeInterval(1)
        var recordedPrompts = await fixture.webhook.recordedPrompts()
        while recordedPrompts.isEmpty, Date() < sendDeadline {
            try await Task.sleep(nanoseconds: 1_000_000)
            recordedPrompts = await fixture.webhook.recordedPrompts()
        }
        let status: AgentTurnStatus? = try fixture.repository.turn(requestId: inFlight.requestId)?.status
        XCTAssertEqual(viewModel.composerText, "ab")
        XCTAssertEqual(status, .superseded)
        XCTAssertEqual(recordedPrompts, ["a"])
    }

    func testFailedReconnectRestoresPreviousConnectionAndActiveProvider() async throws {
        let fixture = try AgentChatViewModelFixture(rejectedWebhookPaths: ["/rejected"])
        let viewModel = AgentSetupViewModel(provider: .tasklet, dependencies: fixture.dependencies)
        let workingURL = try XCTUnwrap(URL(string: "https://93.184.216.34/working"))

        await viewModel.connect(webhookURLText: workingURL.absoluteString, secret: "")
        let workingConnection = AgentConnection(
            provider: .tasklet,
            webhookURL: workingURL,
            auth: .capabilityURL
        )
        XCTAssertEqual(try fixture.connectionStore.load(provider: .tasklet), workingConnection)

        let townURL = try XCTUnwrap(URL(string: "https://93.184.216.34/town"))
        try fixture.connectionStore.save(AgentConnection(
            provider: .town,
            webhookURL: townURL,
            auth: .bearer(secret: "working-secret")
        ))
        fixture.connectionStore.activeProvider = .town

        await viewModel.connect(webhookURLText: "https://93.184.216.34/rejected", secret: "")

        XCTAssertEqual(try fixture.connectionStore.load(provider: .tasklet), workingConnection)
        XCTAssertEqual(fixture.connectionStore.activeProvider, .town)
        XCTAssertTrue(viewModel.isConnected)
        guard case .failed = viewModel.state else {
            XCTFail("Expected rejected reconnect to report a failure")
            return
        }
    }

    func testFailedFirstConnectionDeletesRejectedCredentials() async throws {
        let fixture = try AgentChatViewModelFixture(
            installDefaultConnection: false,
            rejectedWebhookPaths: ["/rejected"]
        )
        fixture.connectionStore.activeProvider = .town
        let viewModel = AgentSetupViewModel(provider: .tasklet, dependencies: fixture.dependencies)

        await viewModel.connect(webhookURLText: "https://93.184.216.34/rejected", secret: "")

        XCTAssertNil(try fixture.connectionStore.load(provider: .tasklet))
        XCTAssertEqual(fixture.connectionStore.activeProvider, .town)
        XCTAssertFalse(viewModel.isConnected)
        guard case .failed = viewModel.state else {
            XCTFail("Expected rejected connection to report a failure")
            return
        }
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

    func testCheckAgainRearmsWatchForSupersededTurn() async throws {
        let completedResult = AgentRelayTurnResult(
            message: "Completed superseded turn",
            links: [],
            completedAt: Date()
        )
        let fixture = try AgentChatViewModelFixture(fetchOutcomes: [
            .pending(expiresAt: Date().addingTimeInterval(3_600)),
            .completed(completedResult),
        ])
        let supersededTurn = makeAgentChatTurn(
            requestId: "request_superseded_check_again",
            provider: .town,
            status: .superseded,
            createdAt: Date().addingTimeInterval(-601)
        )
        try fixture.insertPending(supersededTurn)
        let viewModel = fixture.makeViewModel(provider: .town)

        viewModel.checkAgain(turn: supersededTurn)
        let deadline = Date().addingTimeInterval(1)
        while await fixture.api.fetchWaitMilliseconds.count < 2, Date() < deadline {
            try await Task.sleep(nanoseconds: 1_000_000)
        }

        let fetchWaitMilliseconds: [Int] = await fixture.api.fetchWaitMilliseconds
        let turn = try fixture.repository.turn(requestId: supersededTurn.requestId)
        XCTAssertEqual(fetchWaitMilliseconds, [0, 25_000])
        XCTAssertEqual(turn?.status, .completed)
        XCTAssertEqual(turn?.resultMessage, completedResult.message)
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

    func testClearHistoryDeletesSettledRowsBeyondTranscriptLimitAndRetainsSupersededRows() async throws {
        let fixture = try AgentChatViewModelFixture()
        let settledStatuses: [AgentTurnStatus] = [.completed, .failed, .expired, .collectedElsewhere]
        let settledRequestIds: [String] = (0 ..< 250).map { "request_clear_\($0)" }
        let supersededRequestIds: [String] = (0 ..< 50).map { "request_superseded_\($0)" }
        var completedRequestIds: Set<String> = []
        for (index, requestId) in settledRequestIds.enumerated() {
            let status = settledStatuses[index % settledStatuses.count]
            if status == .completed {
                completedRequestIds.insert(requestId)
            }
            try fixture.insertPending(makeAgentChatTurn(
                requestId: requestId,
                provider: .town,
                status: status
            ))
        }
        for requestId in supersededRequestIds {
            try fixture.insertPending(makeAgentChatTurn(
                requestId: requestId,
                provider: .town,
                status: .superseded
            ))
        }
        let viewModel = fixture.makeViewModel(provider: .town)
        XCTAssertEqual(viewModel.turns.count, 200)

        viewModel.clearHistory()

        let deadline = Date().addingTimeInterval(2)
        while try fixture.repository.turns(limit: .max).count > supersededRequestIds.count, Date() < deadline {
            try await Task.sleep(nanoseconds: 1_000_000)
        }
        let acknowledgedRequestIds = await fixture.api.acknowledgedRequestIds
        let remainingRequestIds = Set(try fixture.repository.turns(limit: .max).map(\.requestId))
        XCTAssertEqual(Set(acknowledgedRequestIds), completedRequestIds)
        XCTAssertEqual(remainingRequestIds, Set(supersededRequestIds))
    }

    func testClearHistoryRetainsOnlyTheRowWhoseAcknowledgementFails() async throws {
        let failedRequestId = "request_ack_failure"
        let requestIds = ["request_ack_success_1", failedRequestId, "request_ack_success_2"]
        let fixture = try AgentChatViewModelFixture(ackFailureRequestIds: [failedRequestId])
        for requestId in requestIds {
            try fixture.insertPending(makeAgentChatTurn(
                requestId: requestId,
                provider: .town,
                status: .completed
            ))
        }
        let viewModel = fixture.makeViewModel(provider: .town)

        viewModel.clearHistory()

        let deadline = Date().addingTimeInterval(2)
        while await fixture.api.acknowledgedRequestIds.count < requestIds.count, Date() < deadline {
            try await Task.sleep(nanoseconds: 1_000_000)
        }
        let remainingTurns = try fixture.repository.turns(limit: .max)
        let acknowledgedRequestIds = await fixture.api.acknowledgedRequestIds
        XCTAssertEqual(remainingTurns.map(\.requestId), [failedRequestId])
        XCTAssertEqual(Set(acknowledgedRequestIds), Set(requestIds))
        XCTAssertNotNil(viewModel.errorMessage)
    }
}

@MainActor
private final class AgentChatViewModelFixture {
    let repository: AgentChatRepository
    let api: RecordingAgentRelayBackendAPI
    let webhook: RecordingAgentWebhookTransport
    let connectionStore: AgentConnectionStore
    let dependencies: AgentRelayDependencies

    private let defaultsSuiteName: String

    init(
        fetchOutcomes: [AgentRelayFetchOutcome] = [],
        ackFailureRequestIds: Set<String> = [],
        installDefaultConnection: Bool = true,
        rejectedWebhookPaths: Set<String> = []
    ) throws {
        let database = try AgentChatDatabase.inMemoryForTests()
        let writer = AgentChatWriter(database: database)
        let repository = AgentChatRepository(database: database)
        let api = RecordingAgentRelayBackendAPI(
            fetchOutcomes: fetchOutcomes,
            ackFailureRequestIds: ackFailureRequestIds
        )
        let webhook = RecordingAgentWebhookTransport(rejectedPaths: rejectedWebhookPaths)
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
        let webhookURL = try XCTUnwrap(URL(string: "https://93.184.216.34/tasklet"))
        if installDefaultConnection {
            try connectionStore.save(AgentConnection(
                provider: .tasklet,
                webhookURL: webhookURL,
                auth: .capabilityURL
            ))
        }
        let mcpURL = try XCTUnwrap(URL(string: "https://api.example.com/api/v2/agent-relay/mcp"))

        self.repository = repository
        self.api = api
        self.webhook = webhook
        self.connectionStore = connectionStore
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
        initialText: String = "",
        waitUntilReady: (@Sendable () async throws -> Void)? = nil
    ) -> AgentChatViewModel {
        guard let waitUntilReady else {
            return AgentChatViewModel(
                provider: provider,
                dependencies: dependencies,
                initialText: initialText
            )
        }
        return AgentChatViewModel(
            provider: provider,
            dependencies: dependencies,
            initialText: initialText,
            waitUntilReady: waitUntilReady
        )
    }

    func insertPending(_ turn: AgentTurn) throws {
        try dependencies.writer.insertPending(turn)
    }
}

private actor AgentChatWaitUntilReadyGate {
    private var continuation: CheckedContinuation<Void, Never>?
    private(set) var hasEntered: Bool = false

    func wait() async {
        hasEntered = true
        await withCheckedContinuation { continuation in
            self.continuation = continuation
        }
    }

    func release() {
        continuation?.resume()
        continuation = nil
    }
}

private actor RecordingAgentRelayBackendAPI: AgentRelayBackendAPI {
    private var mintCount: Int = 0
    private(set) var ackCount: Int = 0
    private(set) var acknowledgedRequestIds: [String] = []
    private(set) var fetchWaitMilliseconds: [Int] = []
    private var fetchOutcomes: [AgentRelayFetchOutcome]
    private let ackFailureRequestIds: Set<String>

    init(
        fetchOutcomes: [AgentRelayFetchOutcome] = [],
        ackFailureRequestIds: Set<String> = []
    ) {
        self.fetchOutcomes = fetchOutcomes
        self.ackFailureRequestIds = ackFailureRequestIds
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
        fetchWaitMilliseconds.append(waitMs)
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
        acknowledgedRequestIds.append(requestId)
        if ackFailureRequestIds.contains(requestId) {
            throw AgentChatViewModelTestError.ackFailed
        }
    }

    func listCompleted() async throws -> [AgentRelayCompletedEntry] {
        []
    }
}

private enum AgentChatViewModelTestError: Error {
    case ackFailed
}

private actor RecordingAgentWebhookTransport: AgentWebhookTransport {
    private var prompts: [String] = []
    private let rejectedPaths: Set<String>

    init(rejectedPaths: Set<String> = []) {
        self.rejectedPaths = rejectedPaths
    }

    func trigger(payload: AgentWebhookPayload, url: URL, auth: AgentWebhookAuth) async throws {
        guard !rejectedPaths.contains(url.path) else {
            throw AgentRelayError.webhookUnreachable
        }
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
