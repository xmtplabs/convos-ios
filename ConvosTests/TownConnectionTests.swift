import ConvosCore
import XCTest
@testable import Convos

final class TownConnectionTests: XCTestCase {
    func testConfigurationRequiresHTTPSWebhookAndBearerSecret() throws {
        XCTAssertThrowsError(
            try TownConnectionConfiguration(
                webhookURLText: "http://town.example/webhook",
                bearerSecret: "secret",
                sharesYourSpaceContext: true
            )
        ) { error in
            XCTAssertEqual(error as? TownConnectionError, .invalidWebhookURL)
        }

        XCTAssertThrowsError(
            try TownConnectionConfiguration(
                webhookURLText: "https://town.example/webhook",
                bearerSecret: "",
                sharesYourSpaceContext: true
            )
        ) { error in
            XCTAssertEqual(error as? TownConnectionError, .missingBearerSecret)
        }
    }

    func testConfigurationUsesTheLiveConvosReturnMCP() throws {
        let configuration = try TownConnectionConfiguration(
            webhookURLText: "https://town.example/webhook",
            bearerSecret: "secret",
            sharesYourSpaceContext: true
        )

        XCTAssertEqual(
            configuration.mcpURL.absoluteString,
            "https://convos-town-bridge.shane-99d.workers.dev/mcp"
        )
    }

    func testConnectionStoreKeepsSecretOutOfDefaults() throws {
        let suiteName = "TownConnectionTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let keychain = MemoryKeychain()
        let configuration = try TownConnectionConfiguration(
            webhookURLText: "https://town.example/webhook",
            bearerSecret: "town-super-secret",
            sharesYourSpaceContext: false
        )

        try TownConnectionStore.save(configuration, defaults: defaults, keychain: keychain)

        XCTAssertEqual(
            TownConnectionStore.configuration(defaults: defaults, keychain: keychain),
            configuration
        )
        XCTAssertFalse(defaults.dictionaryRepresentation().description.contains("town-super-secret"))
    }

    func testReturnedLinksStayWithTheSavedAndSharedMessage() {
        let result = TownTurnResult(
            message: "I made the prototype.",
            links: [
                .init(title: "Open it", url: URL(string: "https://example.com/prototype")!),
            ]
        )

        XCTAssertEqual(
            result.shareText,
            "I made the prototype.\n\nOpen it: https://example.com/prototype"
        )
    }

    func testTownProviderIsMarkedLive() {
        XCTAssertEqual(ExternalAgentProvider.town.displayName, "Town")
        XCTAssertTrue(ExternalAgentProvider.town.chatSubtitle.contains("Live"))
        XCTAssertTrue(ExternalAgentProvider.town.welcomeMessage.contains("save or share"))
    }

}

private final class MemoryKeychain: KeychainServiceProtocol, @unchecked Sendable {
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
