import ConvosCore
import XCTest
@testable import Convos

final class TaskletConnectionTests: XCTestCase {
    func testConfigurationRequiresHTTPSWebhook() {
        XCTAssertThrowsError(
            try TaskletConnectionConfiguration(
                webhookURLText: "http://tasklet.example/webhook",
                sharesYourSpaceContext: true
            )
        ) { error in
            XCTAssertEqual(error as? TaskletConnectionError, .invalidWebhookURL)
        }
    }

    func testConfigurationUsesTheExistingOneRequestMCPBridge() throws {
        let configuration = try TaskletConnectionConfiguration(
            webhookURLText: "https://tasklet.example/webhook/secret",
            sharesYourSpaceContext: true
        )

        XCTAssertEqual(
            configuration.mcpURL.absoluteString,
            "https://convos-town-bridge.shane-99d.workers.dev/mcp"
        )
    }

    func testConnectionStoreKeepsWebhookCapabilityOutOfDefaults() throws {
        let suiteName = "TaskletConnectionTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let keychain = TaskletMemoryKeychain()
        let configuration = try TaskletConnectionConfiguration(
            webhookURLText: "https://tasklet.example/webhook/private-capability",
            sharesYourSpaceContext: false
        )

        try TaskletConnectionStore.save(configuration, defaults: defaults, keychain: keychain)

        XCTAssertEqual(
            TaskletConnectionStore.configuration(defaults: defaults, keychain: keychain),
            configuration
        )
        XCTAssertFalse(defaults.dictionaryRepresentation().description.contains("private-capability"))
    }

    @MainActor
    func testOnlyLiveConfiguredProviderTypesCanEnterTalkTo() {
        let state = AgentChatPrototypeState(restoresConnectedExternalProviders: false)

        state.connect(.tasklet)
        state.connect(.grokBot)
        state.connect(.claudeCode)

        XCTAssertEqual(state.connectedExternalProviders, [.tasklet])
    }

    @MainActor
    func testTalkToContainsRealAndConnectedAgentsWithoutSampleLanes() {
        let liveAgent = AgentChatLane(
            id: "live:space",
            name: "Space Abilities",
            subtitle: "Available in this convo",
            kind: .live(inboxId: "space"),
            profile: nil,
            agentVerification: .unverified
        )

        let lanes = AgentChatLane.available(
            live: [liveAgent],
            connectedExternalProviders: [.town, .tasklet, .grokBot]
        )

        XCTAssertEqual(lanes.map(\.name), ["Space Abilities", "Town", "Tasklet", "Ghost Mode"])
        XCTAssertFalse(lanes.contains { lane in
            if case .prototype = lane.kind { return true }
            return false
        })
    }

    func testTaskletSitsBelowTownAndGrokBotIsComingSoon() throws {
        let townIndex = try XCTUnwrap(ExternalAgentProvider.allCases.firstIndex(of: .town))
        let taskletIndex = try XCTUnwrap(ExternalAgentProvider.allCases.firstIndex(of: .tasklet))

        XCTAssertEqual(taskletIndex, townIndex + 1)
        XCTAssertEqual(ExternalAgentProvider.tasklet.connectionAvailability, .live)
        XCTAssertEqual(ExternalAgentProvider.grokBot.connectionAvailability, .comingSoon)
        XCTAssertEqual(ExternalAgentProvider.grokBot.shortDescription, "Coming soon")
    }
}

private final class TaskletMemoryKeychain: KeychainServiceProtocol, @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String: Data] = [:]

    func saveString(_ value: String, account: String) throws {
        try saveData(Data(value.utf8), account: account)
    }

    func saveData(_ data: Data, account: String) throws {
        lock.withLock { values[account] = data }
    }

    func retrieveString(account: String) throws -> String? {
        try retrieveData(account: account).flatMap { String(data: $0, encoding: .utf8) }
    }

    func retrieveData(account: String) throws -> Data? {
        lock.withLock { values[account] }
    }

    func delete(account: String) throws {
        _ = lock.withLock { values.removeValue(forKey: account) }
    }
}
