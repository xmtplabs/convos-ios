@testable import ConvosCore
import Foundation
import GRDB
import Testing
@preconcurrency import XMTPiOS

// Configure the XMTP endpoint at module load time (before any async code).
// Uses XMTP_NODE_ADDRESS env var when set (e.g. in Docker CI).
private let _configureXMTPEndpoint: Void = {
    if let endpoint = ProcessInfo.processInfo.environment["XMTP_NODE_ADDRESS"] {
        XMTPEnvironment.customLocalAddress = endpoint
    }
}()

/// Regression tests for the forward-secrecy message loss bug.
///
/// Root cause: when the message stream's for-await loop awaits heavy processing
/// inline (findConversation + DB writes + group sync), libxmtp's internal recovery
/// mechanism races ahead with sync_with_conn, advancing the cursor past messages
/// that haven't been delivered to the app yet. Those messages exist in libxmtp's
/// DB but the stream never yields them to Swift.
///
/// Fix location: SyncingManager.runMessageStream() — each received message is
/// dispatched via `Task { await processMessage(...) }` so the for-await loop is
/// never blocked and libxmtp can't race ahead.
///
/// The tests here verify this at the ConvosCore level:
/// - processMessage is called for every streamed message
/// - All text messages end up stored in the ConvosCore GRDB database
/// - Member additions and concurrent syncs during rapid messaging don't cause loss
///
/// Requires: local XMTP node running via `./dev/up` (or XMTP_NODE_ADDRESS set).
@Suite("Forward Secrecy Message Loss Regression", .serialized, .timeLimit(.minutes(5)))
struct ForwardSecrecyReproTests {

    // MARK: - Fix verification (should always pass in CI)

    /// Verifies the producer-consumer pattern in SyncingManager.runMessageStreamIteration()
    /// stores all messages in GRDB during concurrent membership changes.
    ///
    /// The producer (for-await loop) only enqueues into an AsyncStream buffer and
    /// returns immediately. The consumer drains serially on a separate task, so the
    /// stream iterator is never stalled and libxmtp cannot advance the cursor.
    @Test("Producer-consumer stream stores all messages during concurrent membership changes")
    func producerConsumerStreamStoresAllMessages() async throws {
        let (sender, receiver, receiverClientId) = try await makeClients()
        defer {
            try? sender.deleteLocalDatabase()
            try? receiver.deleteLocalDatabase()
        }

        let group = try await sender.conversations.newGroup(with: [receiver.inboxID])
        try await receiver.conversations.sync()

        let receiverGroup = try await receiver.conversations.findGroup(groupId: group.id)!
        try await receiverGroup.updateConsentState(state: .allowed)

        let db = MockDatabaseManager.makeTestDatabase()
        try await insertInbox(id: receiver.inboxID, clientId: receiverClientId, into: db)

        let processor = StreamProcessor(
            identityStore: MockKeychainIdentityStore(),
            databaseWriter: db.dbWriter,
            databaseReader: db.dbReader,
            notificationCenter: MockUserNotificationCenter()
        )

        let syncParams = SyncClientParams(
            client: receiver,
            apiClient: MockAPIClient(),
            consentStates: [.allowed, .unknown]
        )

        let streamTask = Task(priority: .userInitiated) {
            let (buffer, continuation) = AsyncStream<DecodedMessage>.makeStream(bufferingPolicy: .unbounded)

            // Consumer: processes serially, never blocks the producer
            let consumer = Task {
                for await message in buffer {
                    await processor.processMessage(message, params: syncParams, activeConversationId: nil)
                }
            }
            defer {
                continuation.finish()
                consumer.cancel()
            }

            // Producer: enqueues only, never stalls the for-await loop
            let stream = receiver.conversationsProvider.streamAllMessages(
                type: .all,
                consentStates: [.allowed, .unknown],
                onClose: {}
            )
            for try await message in stream {
                continuation.yield(message)
            }
        }

        try await Task.sleep(nanoseconds: 1_000_000_000)

        let messageCount = 100

        let sendTask = Task {
            for i in 1...messageCount {
                _ = try? await group.send(content: "msg-\(i)")
            }
        }

        let joinTask = Task {
            for _ in 1...3 {
                let newClient = try await makeEphemeralClient()
                _ = try? await group.addMembers(inboxIds: [newClient.inboxID])
                try? newClient.deleteLocalDatabase()
            }
        }

        let syncTask = Task {
            for _ in 1...15 {
                _ = try? await receiver.conversations.syncAllConversations(consentStates: nil)
                try? await Task.sleep(nanoseconds: 50_000_000)
            }
        }

        _ = await sendTask.result
        _ = await joinTask.result
        _ = await syncTask.result

        // Wait for non-blocking tasks to finish processing
        try await Task.sleep(nanoseconds: 8_000_000_000)
        streamTask.cancel()

        let storedCount = try await db.dbReader.read { db in
            try DBMessage
                .filter(DBMessage.Columns.conversationId == group.id)
                .filter(DBMessage.Columns.contentType == MessageContentType.text.rawValue)
                .fetchCount(db)
        }

        #expect(storedCount == messageCount, "Non-blocking dispatch should store all messages")
    }

    // MARK: - SyncingManager end-to-end

    /// Verifies that SyncingManager.runMessageStreamIteration() — the actual production
    /// code path — stores all messages in GRDB during concurrent membership changes.
    ///
    /// This test goes through the real SyncingManager rather than reimplementing the
    /// pattern in test code, so it catches regressions if runMessageStreamIteration
    /// is ever reverted to a blocking or unstructured approach.
    @Test("SyncingManager stores all messages end-to-end during concurrent membership changes")
    func syncingManagerStoresAllMessages() async throws {
        let (sender, receiver, receiverClientId) = try await makeClients()
        defer {
            try? sender.deleteLocalDatabase()
            try? receiver.deleteLocalDatabase()
        }

        let group = try await sender.conversations.newGroup(with: [receiver.inboxID])
        try await receiver.conversations.sync()

        let receiverGroup = try await receiver.conversations.findGroup(groupId: group.id)!
        try await receiverGroup.updateConsentState(state: .allowed)

        let db = MockDatabaseManager.makeTestDatabase()
        try await insertInbox(id: receiver.inboxID, clientId: receiverClientId, into: db)

        let syncingManager = SyncingManager(
            identityStore: MockKeychainIdentityStore(),
            databaseWriter: db.dbWriter,
            databaseReader: db.dbReader,
            notificationCenter: MockUserNotificationCenter()
        )

        await syncingManager.start(with: receiver, apiClient: MockAPIClient())

        try await waitUntil(timeout: .seconds(15)) {
            await syncingManager.isSyncReady
        }

        let messageCount = 200

        let sendTask = Task {
            for i in 1...messageCount {
                _ = try? await group.send(content: "msg-\(i)")
            }
        }

        let joinTask = Task {
            for _ in 1...4 {
                let newClient = try await makeEphemeralClient()
                _ = try? await group.addMembers(inboxIds: [newClient.inboxID])
                try? newClient.deleteLocalDatabase()
            }
        }

        let syncTask = Task {
            for _ in 1...20 {
                _ = try? await receiver.conversations.syncAllConversations(consentStates: nil)
                try? await Task.sleep(nanoseconds: 50_000_000)
            }
        }

        _ = await sendTask.result
        _ = await joinTask.result
        _ = await syncTask.result

        try await Task.sleep(nanoseconds: 8_000_000_000)

        await syncingManager.stop()

        let storedCount = try await db.dbReader.read { db in
            try DBMessage
                .filter(DBMessage.Columns.conversationId == group.id)
                .filter(DBMessage.Columns.contentType == MessageContentType.text.rawValue)
                .fetchCount(db)
        }

        #expect(storedCount == messageCount, "SyncingManager lost \(messageCount - storedCount)/\(messageCount) messages")
    }

    // MARK: - Bug reproduction (documents the failure mode)

    /// Reproduces the message loss bug: awaiting processMessage inline blocks the
    /// for-await loop, allowing libxmtp's sync_with_conn to advance the cursor past
    /// undelivered messages (~50% loss under concurrent membership changes).
    ///
    /// This test is expected to fail — it documents what happens when the fix
    /// (Task { } dispatch) is removed from SyncingManager.runMessageStream().
    @Test(
        "Blocking stream callback loses messages - documents bug in stream processing",
        .disabled("Intentional bug reproduction — run manually to verify loss without producer-consumer fix")
    )
    func blockingStreamCallbackLosesMessages() async throws {
        let (sender, receiver, receiverClientId) = try await makeClients()
        defer {
            try? sender.deleteLocalDatabase()
            try? receiver.deleteLocalDatabase()
        }

        let group = try await sender.conversations.newGroup(with: [receiver.inboxID])
        try await receiver.conversations.sync()

        let receiverGroup = try await receiver.conversations.findGroup(groupId: group.id)!
        try await receiverGroup.updateConsentState(state: .allowed)

        let db = MockDatabaseManager.makeTestDatabase()
        try await insertInbox(id: receiver.inboxID, clientId: receiverClientId, into: db)

        let processor = StreamProcessor(
            identityStore: MockKeychainIdentityStore(),
            databaseWriter: db.dbWriter,
            databaseReader: db.dbReader,
            notificationCenter: MockUserNotificationCenter()
        )

        let syncParams = SyncClientParams(
            client: receiver,
            apiClient: MockAPIClient(),
            consentStates: [.allowed, .unknown]
        )

        let streamTask = Task(priority: .userInitiated) {
            let stream = receiver.conversationsProvider.streamAllMessages(
                type: .all,
                consentStates: [.allowed, .unknown],
                onClose: {}
            )
            for try await message in stream {
                // Blocking: awaiting processMessage inline stalls the for-await loop.
                // libxmtp's internal sync_with_conn races ahead and advances the
                // cursor past messages that haven't been yielded to Swift yet.
                await processor.processMessage(
                    message,
                    params: syncParams,
                    activeConversationId: nil
                )
                // Extra sleep to widen the race window, simulating real-world
                // processing latency (network calls, DB writes, permission fetches).
                try? await Task.sleep(nanoseconds: 50_000_000)
            }
        }

        try await Task.sleep(nanoseconds: 1_000_000_000)

        let messageCount = 200

        let sendTask = Task {
            for i in 1...messageCount {
                _ = try? await group.send(content: "msg-\(i)")
            }
        }

        let joinTask = Task {
            for _ in 1...4 {
                let newClient = try await makeEphemeralClient()
                _ = try? await group.addMembers(inboxIds: [newClient.inboxID])
                try? newClient.deleteLocalDatabase()
            }
        }

        let syncTask = Task {
            for _ in 1...20 {
                _ = try? await receiver.conversations.syncAllConversations(consentStates: nil)
                try? await Task.sleep(nanoseconds: 50_000_000)
            }
        }

        _ = await sendTask.result
        _ = await joinTask.result
        _ = await syncTask.result
        try await Task.sleep(nanoseconds: 5_000_000_000)
        streamTask.cancel()

        let storedCount = try await db.dbReader.read { db in
            try DBMessage
                .filter(DBMessage.Columns.conversationId == group.id)
                .filter(DBMessage.Columns.contentType == MessageContentType.text.rawValue)
                .fetchCount(db)
        }

        #expect(storedCount == messageCount, "Stream lost \(messageCount - storedCount)/\(messageCount) messages")
    }

    // MARK: - Helpers

    /// Creates a sender and receiver client pair.
    /// Returns (sender, receiver, receiverClientId) where receiverClientId is a stable
    /// string for the receiver's GRDB inbox record.
    private func makeClients() async throws -> (sender: Client, receiver: Client, receiverClientId: String) {
        let sender = try await makeXMTPClient()
        let receiver = try await makeXMTPClient()
        let receiverClientId = ClientId.generate().value
        return (sender, receiver, receiverClientId)
    }

    private func makeXMTPClient() async throws -> Client {
        var keyBytes = [UInt8](repeating: 0, count: 32)
        _ = SecRandomCopyBytes(kSecRandomDefault, 32, &keyBytes)
        let options = ClientOptions(
            api: .init(env: .local, isSecure: false, appVersion: "convos-tests/1.0.0"),
            codecs: [TextCodec(), GroupUpdatedCodec()],
            dbEncryptionKey: Data(keyBytes)
        )
        return try await Client.create(account: try PrivateKey.generate(), options: options)
    }

    /// Creates a minimal ephemeral XMTP client (used only to add as a group member).
    private func makeEphemeralClient() async throws -> Client {
        var keyBytes = [UInt8](repeating: 0, count: 32)
        _ = SecRandomCopyBytes(kSecRandomDefault, 32, &keyBytes)
        let options = ClientOptions(
            api: .init(env: .local, isSecure: false, appVersion: "convos-tests/1.0.0"),
            dbEncryptionKey: Data(keyBytes)
        )
        return try await Client.create(account: try PrivateKey.generate(), options: options)
    }

    /// Inserts a DBInbox record required by ConversationWriter.createDBConversation().
    private func insertInbox(id inboxId: String, clientId: String, into db: MockDatabaseManager) async throws {
        try await db.dbWriter.write { db in
            try db.execute(
                sql: "INSERT OR IGNORE INTO inbox (clientId, inboxId, createdAt) VALUES (?, ?, ?)",
                arguments: [clientId, inboxId, Date()]
            )
        }
    }
}
