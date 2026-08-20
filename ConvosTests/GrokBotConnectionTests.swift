import ConvosCore
import XCTest
@testable import Convos

final class GrokBotConnectionTests: XCTestCase {
    private let hamilton = GrokBotAgent(
        id: "hamilton",
        name: "Hamilton",
        title: "Operator",
        description: "Gets things done"
    )
    private let cto = GrokBotAgent(
        id: "cto",
        name: "CTO",
        title: nil,
        description: "Technical strategy"
    )

    func testConfigurationRequiresHTTPSBridge() {
        XCTAssertThrowsError(
            try GrokBotConnectionConfiguration(
                sessionId: "session",
                sessionToken: "secret",
                bridgeURLText: "http://bridge.example",
                sharesYourSpaceContext: true
            )
        ) { error in
            XCTAssertEqual(error as? GrokBotConnectionError, .invalidBridgeURL)
        }
    }

    func testConfigurationExpandsEnabledNamedAgents() throws {
        let configuration = try GrokBotConnectionConfiguration(
            sessionId: "session",
            sessionToken: "secret",
            sharesYourSpaceContext: true,
            agents: [hamilton, cto],
            enabledAgentIds: [hamilton.id, cto.id, "missing"]
        )

        XCTAssertEqual(configuration.enabledAgents, [hamilton, cto])
        XCTAssertEqual(configuration.enabledAgentIds, [hamilton.id, cto.id])
        XCTAssertEqual(hamilton.harnessName, "Grok Bot · Hamilton")
    }

    func testStoreKeepsSessionTokenOutOfDefaults() throws {
        let suiteName = "GrokBotConnectionTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let keychain = GrokBotMemoryKeychain()
        let configuration = try GrokBotConnectionConfiguration(
            sessionId: "grok_session_id",
            sessionToken: "private-session-token",
            sharesYourSpaceContext: false,
            agents: [hamilton],
            enabledAgentIds: [hamilton.id]
        )

        try GrokBotConnectionStore.save(configuration, defaults: defaults, keychain: keychain)

        XCTAssertEqual(
            GrokBotConnectionStore.configuration(defaults: defaults, keychain: keychain),
            configuration
        )
        XCTAssertFalse(defaults.dictionaryRepresentation().description.contains("private-session-token"))
    }

    @MainActor
    func testEveryEnabledGrokBotBecomesItsOwnTalkToLane() {
        let lanes = AgentChatLane.available(
            live: [],
            connectedExternalProviders: [.town, .grokBot],
            grokBotAgents: [hamilton, cto]
        )

        XCTAssertEqual(
            lanes.map(\.name),
            ["Space Abilities", "Town", "Grok Bot · Hamilton", "Grok Bot · CTO", "Ghost Mode"]
        )
        XCTAssertEqual(lanes[2].grokBotAgent, hamilton)
        XCTAssertEqual(lanes[3].grokBotAgent, cto)
        XCTAssertNotEqual(lanes[2].id, lanes[3].id)
    }
}

private final class GrokBotMemoryKeychain: KeychainServiceProtocol, @unchecked Sendable {
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
