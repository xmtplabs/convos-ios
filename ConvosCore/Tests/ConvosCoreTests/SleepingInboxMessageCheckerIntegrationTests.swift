@testable import ConvosCore
import Foundation
import GRDB
import Testing
@preconcurrency import XMTPiOS

// Set custom XMTP endpoint at module load time (before any async code)
// @preconcurrency import suppresses strict concurrency warnings for XMTP static properties
private let _configureXMTPEndpoint: Void = {
    if let endpoint = ProcessInfo.processInfo.environment["XMTP_NODE_ADDRESS"] {
        XMTPEnvironment.customLocalAddress = endpoint
    }
}()

/// Integration tests for SleepingInboxMessageChecker using real XMTP network (Docker)
///
/// These tests verify that sleeping inboxes are properly woken when they receive
/// new messages, using real XMTP clients connected to the local Docker node.
@Suite("SleepingInboxMessageChecker Integration Tests", .serialized)
struct SleepingInboxMessageCheckerIntegrationTests {

    // MARK: - Wake on New Message Tests

    @Test("Sleeping inbox wakes when it receives a new message from another client")
    func testSleepingInboxWakesOnNewMessage() async throws {
        let fixtures = IntegrationTestFixtures()

        // Create two XMTP clients: sender and receiver
        let (senderClientProvider, _, _) = try await fixtures.createClient()
        let (receiverClientProvider, receiverClientId, _) = try await fixtures.createClient()

        // Cast to concrete Client type for full XMTP SDK access
        guard let senderClient = senderClientProvider as? Client,
              let receiverClient = receiverClientProvider as? Client else {
            throw IntegrationTestError.failedToCastClient
        }

        // Sender creates a group conversation with receiver
        let group = try await senderClient.conversations.newGroup(
            with: [receiverClient.inboxID],
            name: "Test Group",
            imageUrl: "",
            description: ""
        )

        // Receiver syncs to receive the group
        try await receiverClient.conversations.sync()

        // Save receiver's inbox to database
        try await fixtures.saveInbox(clientId: receiverClientId, inboxId: receiverClient.inboxID)

        // Save the conversation to database (so activity repository can find it)
        try await fixtures.saveConversation(id: group.id, clientId: receiverClientId, inboxId: receiverClient.inboxID)

        // Create lifecycle manager and mark receiver as sleeping (slept 1 hour ago)
        let sleepTime = Date().addingTimeInterval(-3600)
        let lifecycleManager = TestableInboxLifecycleManager()
        await lifecycleManager.setSleeping(clientIds: [receiverClientId], at: sleepTime)

        // Set up activity repository with receiver's data
        let activityRepo = MockInboxActivityRepository()
        activityRepo.activities = [
            InboxActivity(
                clientId: receiverClientId,
                inboxId: receiverClient.inboxID,
                lastActivity: sleepTime.addingTimeInterval(-1800),
                conversationCount: 1
            )
        ]
        activityRepo.mockConversationIds = [
            receiverClientId: [group.id]
        ]

        // Create the checker with real XMTP static operations
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

        // Sender sends a message (this happens AFTER the sleep time)
        try await group.send(content: "Hello from sender!")

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
        let fixtures = IntegrationTestFixtures()

        // Create two XMTP clients
        let (senderClientProvider, _, _) = try await fixtures.createClient()
        let (receiverClientProvider, receiverClientId, _) = try await fixtures.createClient()

        guard let senderClient = senderClientProvider as? Client,
              let receiverClient = receiverClientProvider as? Client else {
            throw IntegrationTestError.failedToCastClient
        }

        // Sender creates a group with receiver
        let group = try await senderClient.conversations.newGroup(
            with: [receiverClient.inboxID],
            name: "Test Group",
            imageUrl: "",
            description: ""
        )

        // Receiver syncs
        try await receiverClient.conversations.sync()

        // Sender sends a message BEFORE we mark receiver as sleeping
        try await group.send(content: "Old message before sleep")

        // Wait for message to propagate through XMTP network before continuing
        // Uses polling instead of fixed delay for reliability across different CI environments
        // (previously used 2s fixed delay which was unreliable with ephemeral Fly.io backends)
        try await waitForMessagePropagation(
            client: receiverClient,
            expectedMessageCount: 1,
            timeout: .seconds(10)
        )

        // Save receiver's inbox and conversation to database
        try await fixtures.saveInbox(clientId: receiverClientId, inboxId: receiverClient.inboxID)
        try await fixtures.saveConversation(id: group.id, clientId: receiverClientId, inboxId: receiverClient.inboxID)

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
                inboxId: receiverClient.inboxID,
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
        let fixtures = IntegrationTestFixtures()

        // Create three clients: sender, receiver1 (will get new message), receiver2 (won't)
        let (senderClientProvider, _, _) = try await fixtures.createClient()
        let (receiver1ClientProvider, receiver1ClientId, _) = try await fixtures.createClient()
        let (receiver2ClientProvider, receiver2ClientId, _) = try await fixtures.createClient()

        guard let senderClient = senderClientProvider as? Client,
              let receiver1Client = receiver1ClientProvider as? Client,
              let receiver2Client = receiver2ClientProvider as? Client else {
            throw IntegrationTestError.failedToCastClient
        }

        // Sender creates two groups
        let group1 = try await senderClient.conversations.newGroup(
            with: [receiver1Client.inboxID],
            name: "Group 1",
            imageUrl: "",
            description: ""
        )

        let group2 = try await senderClient.conversations.newGroup(
            with: [receiver2Client.inboxID],
            name: "Group 2",
            imageUrl: "",
            description: ""
        )

        // Receivers sync
        try await receiver1Client.conversations.sync()
        try await receiver2Client.conversations.sync()

        // Send old message to group2 BEFORE sleep
        try await group2.send(content: "Old message to group 2")

        // Wait for message to propagate through XMTP network before continuing
        // Uses polling instead of fixed delay for reliability across different CI environments
        try await waitForMessagePropagation(
            client: receiver2Client,
            expectedMessageCount: 1,
            timeout: .seconds(10)
        )

        // Save inboxes and conversations
        try await fixtures.saveInbox(clientId: receiver1ClientId, inboxId: receiver1Client.inboxID)
        try await fixtures.saveInbox(clientId: receiver2ClientId, inboxId: receiver2Client.inboxID)
        try await fixtures.saveConversation(id: group1.id, clientId: receiver1ClientId, inboxId: receiver1Client.inboxID)
        try await fixtures.saveConversation(id: group2.id, clientId: receiver2ClientId, inboxId: receiver2Client.inboxID)

        // Mark both receivers as sleeping with a future buffer to account for clock skew
        // between test machine and XMTP backend (especially with ephemeral Fly.io backends in CI).
        let sleepTime = Date().addingTimeInterval(5)
        let lifecycleManager = TestableInboxLifecycleManager()
        await lifecycleManager.setSleeping(clientIds: [receiver1ClientId, receiver2ClientId], at: sleepTime)

        // Wait past the sleep time so the new message gets a timestamp after it
        try await Task.sleep(for: .seconds(5))

        // Send NEW message only to group1 (AFTER sleep)
        try await group1.send(content: "New message to group 1 after sleep!")

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
                inboxId: receiver1Client.inboxID,
                lastActivity: nil,
                conversationCount: 1
            ),
            InboxActivity(
                clientId: receiver2ClientId,
                inboxId: receiver2Client.inboxID,
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

// MARK: - Integration Test Helpers

enum IntegrationTestError: Error {
    case failedToCastClient
}

// MARK: - Integration Test Fixtures

/// Test fixtures for integration tests using real XMTP network
private class IntegrationTestFixtures {
    let environment: AppEnvironment
    let identityStore: MockKeychainIdentityStore
    let databaseManager: MockDatabaseManager
    private var createdClients: [any XMTPClientProvider] = []

    init() {
        self.environment = .tests
        self.identityStore = MockKeychainIdentityStore()
        self.databaseManager = MockDatabaseManager.makeTestDatabase()

        ConvosLog.configure(environment: .tests)
        DeviceInfo.resetForTesting()
        DeviceInfo.configure(MockDeviceInfoProvider())

        // XMTP endpoint is configured at module load time via _configureXMTPEndpoint
    }

    func createClient() async throws -> (client: any XMTPClientProvider, clientId: String, keys: KeychainIdentityKeys) {
        let keys = try await identityStore.generateKeys()
        let clientId = ClientId.generate().value

        let isSecure: Bool
        if let envSecure = ProcessInfo.processInfo.environment["XMTP_IS_SECURE"] {
            isSecure = envSecure.lowercased() == "true" || envSecure == "1"
        } else {
            isSecure = false
        }

        let clientOptions = ClientOptions(
            api: .init(
                env: .local,
                isSecure: isSecure,
                appVersion: "convos-tests/1.0.0"
            ),
            codecs: [
                TextCodec(),
                ReplyCodec(),
                ReactionV2Codec(),
                ReactionCodec(),
                AttachmentCodec(),
                RemoteAttachmentCodec(),
                GroupUpdatedCodec(),
                ExplodeSettingsCodec()
            ],
            dbEncryptionKey: keys.databaseKey,
            dbDirectory: environment.defaultDatabasesDirectory
        )

        let client = try await Client.create(account: keys.signingKey, options: clientOptions)
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

// MARK: - Message Propagation Helper

/// Waits for messages to propagate through the XMTP network by polling the receiver's conversations.
/// This replaces fixed delays with explicit verification, making tests more reliable across
/// different CI environments (local Docker, ephemeral Fly.io backends, etc.).
///
/// - Parameters:
///   - client: The XMTP client to check for received messages
///   - expectedMessageCount: Minimum number of messages expected (default: 1)
///   - timeout: Maximum time to wait for propagation (default: 10 seconds)
/// - Throws: TimeoutError if messages don't propagate within timeout
private func waitForMessagePropagation(
    client: Client,
    expectedMessageCount: Int = 1,
    timeout: Duration = .seconds(10)
) async throws {
    try await waitUntil(timeout: timeout, interval: .milliseconds(100)) {
        // Sync conversations to get latest state from network
        try? await client.conversations.sync()

        // Check if any conversation has the expected number of messages
        let conversations = try? client.conversations.listGroups()
        guard let conversations else { return false }

        for conversation in conversations {
            try? await conversation.sync()
            let messages = try? await conversation.messages()
            if let messages, messages.count >= expectedMessageCount {
                return true
            }
        }
        return false
    }
}
