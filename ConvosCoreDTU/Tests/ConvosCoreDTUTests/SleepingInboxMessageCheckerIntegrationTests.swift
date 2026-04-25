@testable import ConvosCore
@testable import ConvosCoreDTU
import ConvosMessagingProtocols
import ConvosProfiles
import Foundation
import GRDB
import Testing
@preconcurrency import XMTPiOS

// Stage 6f: migrated from
// `ConvosCore/Tests/ConvosCoreTests/SleepingInboxMessageCheckerIntegrationTests.swift`.
//
// Final round (Stage 6f Phase D): the test bodies were rewritten to
// drop the legacy `XMTPiOS.Client` cast and operate on
// `any MessagingClient` / `any MessagingGroup` instead. The
// `IntegrationTestFixtures` helper now produces
// `XMTPiOSMessagingClient` instances directly via the abstraction's
// `MessagingClient.create(...)` static, matching the dual-backend
// pattern in `LegacyTestFixtures` / `DualBackendTestFixtures`.
//
// DTU-gap: the test still skips on the DTU lane because the
// production code under test (`SleepingInboxMessageChecker`) calls
// the static `XMTPStaticOperations.getNewestMessageMetadata` path,
// which is XMTPiOS-only — the DTU adapter's
// `DTUMessagingClient.newestMessageMetadata(...)` deliberately throws
// `DTUMessagingNotSupportedError` because DTU's engine requires a
// universe + actor and has no static metadata-lookup path. See
// `DTUMessagingClient.swift:182-194`. Once the abstraction grows a
// per-instance metadata accessor (and Convos refactors the checker
// to use it), this guard can be replaced with `shouldRunDualBackend`.

// Set custom XMTP endpoint at module load time (before any async code)
// @preconcurrency import suppresses strict concurrency warnings for XMTP static properties
private let _configureXMTPEndpoint: Void = {
    if let endpoint = ProcessInfo.processInfo.environment["XMTP_NODE_ADDRESS"] {
        XMTPEnvironment.customLocalAddress = endpoint
    }
}()

/// Centralised skip reason for the DTU lane. Keeps the per-test
/// `shouldRun(reason:)` calls within the lint line-length limit.
private let dtuStaticMetadataGap: String = """
DTU-gap: SleepingInboxMessageChecker drives the static \
`XMTPStaticOperations.getNewestMessageMetadata` path; the DTU \
adapter throws `DTUMessagingNotSupportedError` because the engine \
has no static metadata-lookup path (universe + actor required).
"""

/// Integration tests for SleepingInboxMessageChecker using real XMTP network (Docker)
///
/// These tests verify that sleeping inboxes are properly woken when they receive
/// new messages, using real XMTP clients connected to the local Docker node.
@Suite("SleepingInboxMessageChecker Integration Tests", .serialized, .timeLimit(.minutes(2)))
struct SleepingInboxMessageCheckerIntegrationTests {
    // MARK: - Wake on New Message Tests

    @Test("Sleeping inbox wakes when it receives a new message from another client")
    func testSleepingInboxWakesOnNewMessage() async throws {
        guard LegacyFixtureBackendGuard.shouldRun(reason: dtuStaticMetadataGap) else { return }
        let fixtures = IntegrationTestFixtures()

        // Create two MessagingClients: sender and receiver. The
        // abstraction surface is backend-agnostic; this XMTPiOS-only
        // path is selected by the legacy guard above. Phase A of Stage 6e
        // already lifted MessagingClient creation off the raw
        // XMTPiOS.Client cast.
        let (senderClient, _, _) = try await fixtures.createClient()
        let (receiverClient, receiverClientId, _) = try await fixtures.createClient()

        // Sender creates a group conversation with receiver via
        // `MessagingConversations.newGroup(withInboxIds:)` — replaces
        // the legacy `senderClient.conversations.newGroup(with:)` raw
        // XMTPiOS call.
        let group = try await senderClient.conversations.newGroup(
            withInboxIds: [receiverClient.inboxId],
            name: "Test Group",
            imageUrl: "",
            description: ""
        )

        // Receiver syncs to receive the group
        try await receiverClient.conversations.sync()

        // Save receiver's inbox to database
        try await fixtures.saveInbox(clientId: receiverClientId, inboxId: receiverClient.inboxId)

        // Save the conversation to database (so activity repository can find it)
        try await fixtures.saveConversation(id: group.id, clientId: receiverClientId, inboxId: receiverClient.inboxId)

        // Create lifecycle manager and mark receiver as sleeping (slept 1 hour ago)
        let sleepTime = Date().addingTimeInterval(-3600)
        let lifecycleManager = TestableInboxLifecycleManager()
        await lifecycleManager.setSleeping(clientIds: [receiverClientId], at: sleepTime)

        // Set up activity repository with receiver's data
        let activityRepo = MockInboxActivityRepository()
        activityRepo.activities = [
            InboxActivity(
                clientId: receiverClientId,
                inboxId: receiverClient.inboxId,
                lastActivity: sleepTime.addingTimeInterval(-1800),
                conversationCount: 1
            )
        ]
        activityRepo.mockConversationIds = [
            receiverClientId: [group.id]
        ]

        // Create the checker with real XMTP static operations.
        // `Client.self` is still XMTPiOS-bound here because the static
        // metadata path is XMTPiOS-only (see DTU-gap note above).
        let appLifecycle = MockAppLifecycleProvider(
            didEnterBackgroundNotification: .init("TestBackground"),
            willEnterForegroundNotification: .init("TestForeground"),
            didBecomeActiveNotification: .init("TestActive")
        )

        let checker = SleepingInboxMessageChecker(
            checkInterval: 60,
            environment: .tests,
            activityRepository: activityRepo,
            lifecycleManager: lifecycleManager,
            appLifecycle: appLifecycle,
            xmtpStaticOperations: Client.self
        )

        // Sender sends a message via the abstraction's optimistic
        // send + explicit publish (replaces raw `group.send(content:)`).
        try await sendText(group: group, text: "Hello from sender!")

        // Wait for message to propagate through XMTP network before checking
        // Uses polling instead of fixed delay for reliability across different CI environments
        try await waitForMessagePropagation(
            client: receiverClient,
            expectedMessageCount: 1,
            timeout: .seconds(10)
        )

        // Run the checker - should detect new message and wake receiver
        await checker.checkNow()

        // Verify receiver was woken
        let wokenClientIds = await lifecycleManager.wokenClientIds
        #expect(wokenClientIds.contains(receiverClientId),
                "Sleeping inbox should be woken when it receives a new message")

        // Cleanup
        try await fixtures.cleanup()
    }

    @Test("Sleeping inbox does NOT wake when no new messages after sleep time")
    func testSleepingInboxDoesNotWakeWithoutNewMessages() async throws {
        guard LegacyFixtureBackendGuard.shouldRun(reason: dtuStaticMetadataGap) else { return }
        let fixtures = IntegrationTestFixtures()

        // Create two MessagingClients
        let (senderClient, _, _) = try await fixtures.createClient()
        let (receiverClient, receiverClientId, _) = try await fixtures.createClient()

        // Sender creates a group with receiver
        let group = try await senderClient.conversations.newGroup(
            withInboxIds: [receiverClient.inboxId],
            name: "Test Group",
            imageUrl: "",
            description: ""
        )

        // Receiver syncs
        try await receiverClient.conversations.sync()

        // Sender sends a message BEFORE we mark receiver as sleeping
        try await sendText(group: group, text: "Old message before sleep")

        // Wait for message to propagate through XMTP network before continuing
        // Uses polling instead of fixed delay for reliability across different CI environments
        // (previously used 2s fixed delay which was unreliable with ephemeral Fly.io backends)
        try await waitForMessagePropagation(
            client: receiverClient,
            expectedMessageCount: 1,
            timeout: .seconds(10)
        )

        // Save receiver's inbox and conversation to database
        try await fixtures.saveInbox(clientId: receiverClientId, inboxId: receiverClient.inboxId)
        try await fixtures.saveConversation(id: group.id, clientId: receiverClientId, inboxId: receiverClient.inboxId)

        // Now mark receiver as sleeping (AFTER the message was sent)
        // Add 5 second buffer for clock skew between test machine and XMTP backend
        // (especially relevant with ephemeral Fly.io backends in CI)
        let sleepTime = Date().addingTimeInterval(5)
        let lifecycleManager = TestableInboxLifecycleManager()
        await lifecycleManager.setSleeping(clientIds: [receiverClientId], at: sleepTime)

        // Set up activity repository
        let activityRepo = MockInboxActivityRepository()
        activityRepo.activities = [
            InboxActivity(
                clientId: receiverClientId,
                inboxId: receiverClient.inboxId,
                lastActivity: sleepTime.addingTimeInterval(-5),
                conversationCount: 1
            )
        ]
        activityRepo.mockConversationIds = [
            receiverClientId: [group.id]
        ]

        let appLifecycle = MockAppLifecycleProvider(
            didEnterBackgroundNotification: .init("TestBackground"),
            willEnterForegroundNotification: .init("TestForeground"),
            didBecomeActiveNotification: .init("TestActive")
        )

        let checker = SleepingInboxMessageChecker(
            checkInterval: 60,
            environment: .tests,
            activityRepository: activityRepo,
            lifecycleManager: lifecycleManager,
            appLifecycle: appLifecycle,
            xmtpStaticOperations: Client.self
        )

        // Run the checker - should NOT wake because message is older than sleep time
        await checker.checkNow()

        // Verify receiver was NOT woken
        let wokenClientIds = await lifecycleManager.wokenClientIds
        #expect(!wokenClientIds.contains(receiverClientId),
                "Sleeping inbox should NOT wake when message is older than sleep time")

        try await fixtures.cleanup()
    }

    @Test("Multiple sleeping inboxes: only those with new messages wake")
    func testMultipleSleepingInboxesSelectiveWake() async throws {
        guard LegacyFixtureBackendGuard.shouldRun(reason: dtuStaticMetadataGap) else { return }
        let fixtures = IntegrationTestFixtures()

        // Create three clients: sender, receiver1 (will get new message), receiver2 (won't)
        let (senderClient, _, _) = try await fixtures.createClient()
        let (receiver1Client, receiver1ClientId, _) = try await fixtures.createClient()
        let (receiver2Client, receiver2ClientId, _) = try await fixtures.createClient()

        // Sender creates two groups
        let group1 = try await senderClient.conversations.newGroup(
            withInboxIds: [receiver1Client.inboxId],
            name: "Group 1",
            imageUrl: "",
            description: ""
        )

        let group2 = try await senderClient.conversations.newGroup(
            withInboxIds: [receiver2Client.inboxId],
            name: "Group 2",
            imageUrl: "",
            description: ""
        )

        // Receivers sync
        try await receiver1Client.conversations.sync()
        try await receiver2Client.conversations.sync()

        // Send old message to group2 BEFORE sleep
        try await sendText(group: group2, text: "Old message to group 2")

        // Wait for message to propagate through XMTP network before continuing
        // Uses polling instead of fixed delay for reliability across different CI environments
        try await waitForMessagePropagation(
            client: receiver2Client,
            expectedMessageCount: 1,
            timeout: .seconds(10)
        )

        // Save inboxes and conversations
        try await fixtures.saveInbox(clientId: receiver1ClientId, inboxId: receiver1Client.inboxId)
        try await fixtures.saveInbox(clientId: receiver2ClientId, inboxId: receiver2Client.inboxId)
        try await fixtures.saveConversation(id: group1.id, clientId: receiver1ClientId, inboxId: receiver1Client.inboxId)
        try await fixtures.saveConversation(id: group2.id, clientId: receiver2ClientId, inboxId: receiver2Client.inboxId)

        // Wait for clock skew buffer before setting sleep time.
        // This ensures the "old" message timestamp from the XMTP backend
        // is clearly before the sleep time, even with clock skew.
        try await Task.sleep(for: .seconds(5))

        // Mark both receivers as sleeping
        let sleepTime = Date()
        let lifecycleManager = TestableInboxLifecycleManager()
        await lifecycleManager.setSleeping(clientIds: [receiver1ClientId, receiver2ClientId], at: sleepTime)

        // Wait past the sleep time so the new message gets a timestamp after it
        try await Task.sleep(for: .seconds(5))

        // Send NEW message only to group1 (AFTER sleep)
        try await sendText(group: group1, text: "New message to group 1 after sleep!")

        // Wait for message to propagate through XMTP network before checking
        try await waitForMessagePropagation(
            client: receiver1Client,
            expectedMessageCount: 1,
            timeout: .seconds(10)
        )

        // Set up activity repository
        let activityRepo = MockInboxActivityRepository()
        activityRepo.activities = [
            InboxActivity(
                clientId: receiver1ClientId,
                inboxId: receiver1Client.inboxId,
                lastActivity: nil,
                conversationCount: 1
            ),
            InboxActivity(
                clientId: receiver2ClientId,
                inboxId: receiver2Client.inboxId,
                lastActivity: nil,
                conversationCount: 1
            )
        ]
        activityRepo.mockConversationIds = [
            receiver1ClientId: [group1.id],
            receiver2ClientId: [group2.id]
        ]

        let appLifecycle = MockAppLifecycleProvider(
            didEnterBackgroundNotification: .init("TestBackground"),
            willEnterForegroundNotification: .init("TestForeground"),
            didBecomeActiveNotification: .init("TestActive")
        )

        let checker = SleepingInboxMessageChecker(
            checkInterval: 60,
            environment: .tests,
            activityRepository: activityRepo,
            lifecycleManager: lifecycleManager,
            appLifecycle: appLifecycle,
            xmtpStaticOperations: Client.self
        )

        // Run the checker
        await checker.checkNow()

        // Verify only receiver1 was woken (got new message after sleep)
        let wokenClientIds = await lifecycleManager.wokenClientIds
        #expect(wokenClientIds.contains(receiver1ClientId),
                "Receiver 1 should wake - got new message after sleep")
        #expect(!wokenClientIds.contains(receiver2ClientId),
                "Receiver 2 should NOT wake - message was before sleep")

        try await fixtures.cleanup()
    }
}

// MARK: - Integration Test Fixtures

/// Test fixtures for integration tests using real XMTP network.
///
/// Final round (Stage 6f Phase D): rewritten to expose
/// `any MessagingClient` instead of the legacy
/// `any XMTPClientProvider`. Construction still goes through
/// XMTPiOS (`XMTPiOSMessagingClient.create(...)`) because the
/// SleepingInboxMessageChecker static path is XMTPiOS-only — see the
/// DTU-gap note at the top of this file.
private final class IntegrationTestFixtures {
    let environment: AppEnvironment
    let identityStore: MockKeychainIdentityStore
    let databaseManager: MockDatabaseManager
    private var createdClients: [any MessagingClient] = []

    init() {
        self.environment = .tests
        self.identityStore = MockKeychainIdentityStore()
        self.databaseManager = MockDatabaseManager.makeTestDatabase()

        ConvosLog.configure(environment: .tests)
        DeviceInfo.resetForTesting()
        DeviceInfo.configure(MockDeviceInfoProvider())

        // XMTP endpoint is configured at module load time via _configureXMTPEndpoint
    }

    func createClient() async throws -> (
        client: any MessagingClient,
        clientId: String,
        keys: KeychainIdentityKeys
    ) {
        let keys = try await identityStore.generateKeys()
        let clientId = ClientId.generate().value

        let isSecure: Bool
        if let envSecure = ProcessInfo.processInfo.environment["XMTP_IS_SECURE"] {
            isSecure = envSecure.lowercased() == "true" || envSecure == "1"
        } else {
            isSecure = false
        }

        // Use the abstraction's `MessagingClientConfig` shape; the
        // XMTPiOS adapter (`XMTPiOSMessagingClient.create(...)`) builds
        // the underlying `ClientOptions` from these fields and registers
        // the same codec set the legacy path used.
        let config = MessagingClientConfig(
            apiEnv: .local,
            customLocalAddress: ProcessInfo.processInfo.environment["XMTP_NODE_ADDRESS"],
            isSecure: isSecure,
            appVersion: "convos-tests/1.0.0",
            dbEncryptionKey: keys.databaseKey,
            dbDirectory: environment.defaultDatabasesDirectory,
            deviceSyncEnabled: false,
            codecs: []
        )

        let client: any MessagingClient = try await XMTPiOSMessagingClient.create(
            signer: keys.signingKey,
            config: config
        )
        createdClients.append(client)

        _ = try await identityStore.save(inboxId: client.inboxId, clientId: clientId, keys: keys)

        return (client, clientId, keys)
    }

    func saveInbox(clientId: String, inboxId: String) async throws {
        try await databaseManager.dbWriter.write { db in
            try db.execute(
                sql: "INSERT INTO inbox (clientId, inboxId, createdAt) VALUES (?, ?, ?)",
                arguments: [clientId, inboxId, Date()]
            )
        }
    }

    func saveConversation(id: String, clientId: String, inboxId: String) async throws {
        let clientConversationId = "\(clientId)-\(id)"
        let inviteTag = UUID().uuidString
        try await databaseManager.dbWriter.write { db in
            try db.execute(
                sql: """
                    INSERT INTO conversation (id, inboxId, clientId, clientConversationId, inviteTag, creatorId, kind, consent, createdAt)
                    VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
                    """,
                arguments: [id, inboxId, clientId, clientConversationId, inviteTag, "", "group", "allowed", Date()]
            )
        }
    }

    func cleanup() async throws {
        for client in createdClients {
            try? client.deleteLocalDatabase()
        }
        createdClients.removeAll()
        try await identityStore.deleteAll()
        try databaseManager.erase()
    }
}

// MARK: - Send + propagation helpers

/// Sends a plain-text message through the abstraction's optimistic
/// send + explicit publish path. Replaces the legacy raw
/// `XMTPiOS.Conversation.send(content:)` call site.
///
/// XMTPiOS's `sendOptimistic` stores locally with delivery status
/// `.unpublished`; `publish()` flushes any pending optimistic messages
/// to the network. This matches the dual-step pattern already used by
/// `CreateGroupSendListCrossBackendTests`.
private func sendText(group: any MessagingGroup, text: String) async throws {
    let encoded = MessagingEncodedContent(
        type: .text,
        parameters: [:],
        content: Data(text.utf8),
        fallback: nil,
        compression: nil
    )
    _ = try await group.sendOptimistic(encodedContent: encoded, options: nil)
    try await group.publish()
}

/// Waits for messages to propagate through the XMTP network by
/// polling the receiver's conversations.
///
/// Final round: takes `any MessagingClient` instead of the raw
/// `XMTPiOS.Client` so the helper compiles backend-agnostically. Uses
/// the abstraction's `MessagingConversations.listGroups(query:)` and
/// `MessagingConversationCore.messages(query:)` instead of the legacy
/// XMTPiOS calls — both are backed by libxmtp on the XMTPiOS adapter
/// and by the DTU engine on the DTU adapter, but only XMTPiOS is
/// exercised here because the legacy guard skips DTU.
///
/// - Parameters:
///   - client: The MessagingClient to check for received messages
///   - expectedMessageCount: Minimum number of messages expected (default: 1)
///   - timeout: Maximum time to wait for propagation (default: 10 seconds)
/// - Throws: TimeoutError if messages don't propagate within timeout
private func waitForMessagePropagation(
    client: any MessagingClient,
    expectedMessageCount: Int = 1,
    timeout: Duration = .seconds(10)
) async throws {
    try await legacyWaitUntil(timeout: timeout, interval: .milliseconds(100)) {
        // Sync conversations to get latest state from network
        try? await client.conversations.sync()

        // Check if any conversation has the expected number of messages
        let conversations = try? await client.conversations.listGroups(
            query: MessagingConversationQuery()
        )
        guard let conversations else { return false }

        for conversation in conversations {
            try? await conversation.sync()
            let messages = try? await conversation.messages(query: MessagingMessageQuery())
            if let messages, messages.count >= expectedMessageCount {
                return true
            }
        }
        return false
    }
}
