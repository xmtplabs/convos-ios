@testable import ConvosCore
import Foundation
import Testing

@Suite("AgentRelay connections and validation", .serialized)
struct AgentRelayConnectionAndValidationTests {
    @Test("Town bearer secrets never enter UserDefaults")
    func townSecretStaysInKeychain() throws {
        let suite = "group.agent-relay-town-\(UUID().uuidString)"
        defer { UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite) }
        let keychain = InMemoryAgentRelayKeychain()
        let environment = makeConfiguredEnvironment(local: false, suiteName: suite)
        let store = AgentConnectionStore(environment: environment, keychain: keychain)

        try store.save(makeAgentConnection(provider: .town))

        let defaults = UserDefaults(suiteName: suite)?.dictionaryRepresentation() ?? [:]
        let values = defaults.values
        let defaultsText = values.map { String(describing: $0) }.joined(separator: " ")
        #expect(!defaultsText.contains("bearer-secret"))
        #expect(try keychain.retrieveString(account: "agentRelay.town.secret") == "bearer-secret")
        #expect(try store.load(provider: .town) == makeAgentConnection(provider: .town))
    }

    @Test("Tasklet capability URL never enters UserDefaults")
    func taskletURLStaysInKeychain() throws {
        let suite = "group.agent-relay-tasklet-\(UUID().uuidString)"
        defer { UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite) }
        let keychain = InMemoryAgentRelayKeychain()
        let environment = makeConfiguredEnvironment(local: false, suiteName: suite)
        let store = AgentConnectionStore(environment: environment, keychain: keychain)
        let connection = makeAgentConnection(provider: .tasklet)

        try store.save(connection)

        let defaults = UserDefaults(suiteName: suite)?.dictionaryRepresentation() ?? [:]
        let values = defaults.values
        let defaultsText = values.map { String(describing: $0) }.joined(separator: " ")
        #expect(!defaultsText.contains(connection.webhookURL.absoluteString))
        #expect(try keychain.retrieveString(account: "agentRelay.tasklet.webhookURL") == connection.webhookURL.absoluteString)
        #expect(try store.load(provider: .tasklet) == connection)
    }

    @Test("disconnect clears provider state and the active provider")
    func deleteClearsConnectionAndActiveProvider() throws {
        let suite = "group.agent-relay-delete-\(UUID().uuidString)"
        defer { UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite) }
        let store = AgentConnectionStore(
            environment: makeConfiguredEnvironment(local: false, suiteName: suite),
            keychain: InMemoryAgentRelayKeychain()
        )
        try store.save(makeAgentConnection())

        try store.delete(provider: .town)

        #expect(try store.load(provider: .town) == nil)
        #expect(store.activeProvider == nil)
    }

    @Test("dev rejects HTTP webhook URLs")
    func devRejectsHTTP() {
        expectValidationFailure("http://hooks.town.com/x")
    }

    @Test("dev rejects localhost")
    func devRejectsLocalhost() {
        expectValidationFailure("https://localhost/x")
    }

    @Test("dev rejects private IPv4")
    func devRejectsPrivateIPv4() {
        expectValidationFailure("https://10.0.0.1/x")
    }

    @Test("dev rejects IPv6 loopback")
    func devRejectsIPv6Loopback() {
        expectValidationFailure("https://[::1]/x")
    }

    @Test("dev rejects IPv4-mapped IPv6")
    func devRejectsMappedIPv6() {
        expectValidationFailure("https://[::ffff:127.0.0.1]/x")
    }

    @Test("dev rejects integer IPv4")
    func devRejectsIntegerIPv4() {
        expectValidationFailure("https://2130706433/")
    }

    @Test("dev rejects hexadecimal IPv4")
    func devRejectsHexIPv4() {
        expectValidationFailure("https://0x7f000001/")
    }

    @Test("dev rejects URL userinfo")
    func devRejectsUserInfo() {
        expectValidationFailure("https://user:pw@hooks.town.com/x")
    }

    @Test("dev rejects local network hostnames")
    func devRejectsDotLocal() {
        expectValidationFailure("https://foo.local/x")
    }

    @Test("dev accepts HTTPS host and explicit port")
    func devAcceptsHTTPSPort() throws {
        let url = try WebhookURLValidator(environment: makeConfiguredEnvironment(local: false)).validate("https://hooks.town.com:8443/x")
        #expect(url.port == 8_443)
    }

    @Test("dev accepts a long Tasklet capability URL")
    func devAcceptsLongCapabilityURL() throws {
        let longURL = "https://hooks.tasklet.example/webhook?token=\(String(repeating: "a", count: 1_024))"
        let url = try WebhookURLValidator(environment: makeConfiguredEnvironment(local: false)).validate(longURL)
        #expect(url.absoluteString == longURL)
    }

    @Test("local accepts exact loopback over HTTP")
    func localAcceptsLoopback() throws {
        let string = "http://127.0.0.1:4101/webhook"
        let url = try WebhookURLValidator(environment: makeConfiguredEnvironment(local: true)).validate(string)
        #expect(url.absoluteString == string)
    }

    @Test("local still rejects private non-loopback addresses")
    func localRejectsPrivateIPv4() {
        let validator = WebhookURLValidator(environment: makeConfiguredEnvironment(local: true))
        #expect(throws: AgentRelayError.self) {
            try validator.validate("https://10.0.0.1/x")
        }
    }

    @Test("draft take drains a matching fresh draft")
    func draftTakeDrainsMatchingDraft() {
        let suite = "group.agent-relay-draft-\(UUID().uuidString)"
        defer { UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite) }
        let store = PendingComposerDraftStore(environment: makeConfiguredEnvironment(local: false, suiteName: suite))
        let draft = PendingComposerDraft(conversationId: "conversation", text: "Draft", stagedAt: Date())
        store.stage(draft)

        #expect(store.take(for: "conversation") == draft)
        #expect(store.take(for: "conversation") == nil)
    }

    @Test("draft mismatch does not clear the staged draft")
    func draftMismatchPreservesDraft() {
        let suite = "group.agent-relay-mismatch-\(UUID().uuidString)"
        defer { UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite) }
        let store = PendingComposerDraftStore(environment: makeConfiguredEnvironment(local: false, suiteName: suite))
        let draft = PendingComposerDraft(conversationId: "target", text: "Draft", stagedAt: Date())
        store.stage(draft)

        #expect(store.take(for: "other") == nil)
        #expect(store.take(for: "target") == draft)
    }

    @Test("stale draft is cleared instead of returned")
    func staleDraftIsDiscarded() {
        let suite = "group.agent-relay-stale-\(UUID().uuidString)"
        defer { UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite) }
        let store = PendingComposerDraftStore(environment: makeConfiguredEnvironment(local: false, suiteName: suite))
        store.stage(PendingComposerDraft(conversationId: "target", text: "Old", stagedAt: Date().addingTimeInterval(-601)))

        #expect(store.take(for: "target") == nil)
        #expect(store.take(for: "target") == nil)
    }

    @Test("push fixture parses from APNs userInfo")
    func pushFixtureParses() throws {
        let userInfo = try fixtureUserInfo()
        let parsed = AgentRelayPushPayload.parse(userInfo)

        #expect(parsed?.requestId == "request_kJ83exampleexampleexample")
        #expect(parsed?.provider == .town)
        #expect(parsed?.apiJWT.contains(".") == true)
    }

    @Test("push fixture without scoped JWT is rejected")
    func pushFixtureRequiresJWT() throws {
        var userInfo = try fixtureUserInfo()
        userInfo.removeValue(forKey: "apiJWT")
        #expect(AgentRelayPushPayload.parse(userInfo) == nil)
    }

    @Test("reset wipes rows, credentials, defaults, and staged draft")
    func resetWipesAllRelayState() throws {
        let environment = AppEnvironment.tests
        let suite = environment.appGroupIdentifier
        UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite)
        defer { UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite) }
        let keychain = InMemoryAgentRelayKeychain()
        let database = try AgentChatDatabase(environment: environment)
        let writer = AgentChatWriter(database: database)
        try writer.deleteAll()
        try writer.insertPending(makeAgentTurn(requestId: "request_reset"))
        let connections = AgentConnectionStore(environment: environment, keychain: keychain)
        try connections.save(makeAgentConnection(provider: .town))
        try connections.save(makeAgentConnection(provider: .tasklet))
        PendingComposerDraftStore(environment: environment).stage(
            PendingComposerDraft(conversationId: "conversation", text: "Draft", stagedAt: Date())
        )

        try AgentRelayReset.wipeAll(environment: environment, keychain: keychain)

        #expect(try AgentChatRepository(database: database).turns(limit: 10).isEmpty)
        #expect(try keychain.retrieveString(account: "agentRelay.town.secret") == nil)
        #expect(try keychain.retrieveString(account: "agentRelay.tasklet.webhookURL") == nil)
        #expect(connections.activeProvider == nil)
        #expect(PendingComposerDraftStore(environment: environment).take(for: "conversation") == nil)

        try connections.save(makeAgentConnection(provider: .tasklet))
        #expect(try connections.load(provider: .tasklet) == makeAgentConnection(provider: .tasklet))
    }

    private func expectValidationFailure(_ string: String) {
        let validator = WebhookURLValidator(environment: makeConfiguredEnvironment(local: false))
        #expect(throws: AgentRelayError.self) {
            try validator.validate(string)
        }
    }

    private func fixtureUserInfo() throws -> [AnyHashable: Any] {
        let testFile = URL(fileURLWithPath: #filePath)
        let fixtureURL = testFile.deletingLastPathComponent().appendingPathComponent("Fixtures/agent-relay-push.json")
        let data = try Data(contentsOf: fixtureURL)
        let object = try JSONSerialization.jsonObject(with: data)
        let dictionary = try #require(object as? [String: Any])
        return Dictionary(uniqueKeysWithValues: dictionary.map { key, value in
            (AnyHashable(key), value)
        })
    }
}
