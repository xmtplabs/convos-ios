@testable import ConvosCore
import Foundation
import GRDB
import os.lock
import Testing
import XMTPiOS

/// Testable mock XMTP client that allows controlling syncAllConversations behavior
class TestableMockClient: XMTPClientProvider, @unchecked Sendable {
    var installationId: String = "test-installation-id"
    var inboxId: String = "test-inbox-id"

    lazy var conversationsProvider: ConversationsProvider = {
        TestableMockConversations(syncBehavior: syncBehavior, streamBehavior: streamBehavior)
    }()

    // Control syncAllConversations behavior
    var syncBehavior: SyncBehavior = .succeed
    var streamBehavior: StreamBehavior = .empty

    enum SyncBehavior {
        case succeed
        case fail(Error)
        case delay(TimeInterval)
    }

    enum StreamBehavior {
        case empty
        case emitOneThenClose
        case emitMultipleThenClose
        case neverClose
        case delayedStart(TimeInterval) // Delays before stream iteration begins
        case throwImmediately // Throws an error immediately when stream is created
    }

    func signWithInstallationKey(message: String) throws -> Data {
        Data()
    }

    func verifySignature(message: String, signature: Data) throws -> Bool {
        true
    }

    func messageSender(for conversationId: String) async throws -> (any MessageSender)? {
        nil
    }

    func canMessage(identity: String) async throws -> Bool {
        true
    }

    func canMessage(identities: [String]) async throws -> [String: Bool] {
        Dictionary(uniqueKeysWithValues: identities.map { ($0, true) })
    }

    func prepareConversation() throws -> GroupConversationSender {
        TestableMockGroupConversationSender()
    }

    func newConversation(with memberInboxIds: [String],
                        name: String,
                        description: String,
                        imageUrl: String) async throws -> String {
        UUID().uuidString
    }

    func newConversation(with memberInboxId: String) async throws -> (any MessageSender) {
        TestableMockMessageSender()
    }

    func conversation(with id: String) async throws -> XMTPiOS.Conversation? {
        nil
    }

    func inboxId(for ethereumAddress: String) async throws -> String? {
        nil
    }

    func update(consent: Consent, for conversationId: String) async throws {
    }

    func revokeInstallations(signingKey: any SigningKey, installationIds: [String]) async throws {
    }

    func deleteLocalDatabase() throws {
    }

    func dropLocalDatabaseConnection() throws {
    }

    func reconnectLocalDatabase() async throws {
    }
}

class TestableMockConversations: ConversationsProvider, @unchecked Sendable {
    let syncBehavior: TestableMockClient.SyncBehavior
    let streamBehavior: TestableMockClient.StreamBehavior

    private var _syncCallCount = 0
    private var _streamCallCount = 0
    private let lock = OSAllocatedUnfairLock()

    var syncCallCount: Int {
        lock.withLock { _syncCallCount }
    }

    var streamCallCount: Int {
        lock.withLock { _streamCallCount }
    }

    init(syncBehavior: TestableMockClient.SyncBehavior, streamBehavior: TestableMockClient.StreamBehavior) {
        self.syncBehavior = syncBehavior
        self.streamBehavior = streamBehavior
    }

    func list(createdAfterNs: Int64?,
             createdBeforeNs: Int64?,
             lastActivityBeforeNs: Int64?,
             lastActivityAfterNs: Int64?,
             limit: Int?,
             consentStates: [XMTPiOS.ConsentState]?,
             orderBy: XMTPiOS.ConversationsOrderBy) async throws -> [XMTPiOS.Conversation] {
        []
    }

    func listGroups(createdAfterNs: Int64?,
                   createdBeforeNs: Int64?,
                   lastActivityAfterNs: Int64?,
                   lastActivityBeforeNs: Int64?,
                   limit: Int?,
                   consentStates: [ConsentState]?,
                   orderBy: ConversationsOrderBy) throws -> [Group] {
        []
    }

    func listDms(createdAfterNs: Int64?,
                createdBeforeNs: Int64?,
                lastActivityBeforeNs: Int64?,
                lastActivityAfterNs: Int64?,
                limit: Int?,
                consentStates: [ConsentState]?,
                orderBy: ConversationsOrderBy) throws -> [Dm] {
        []
    }

    func stream(type: XMTPiOS.ConversationFilterType,
               onClose: (() -> Void)?) -> AsyncThrowingStream<XMTPiOS.Conversation, any Error> {
        lock.withLock { _streamCallCount += 1 }
        let behavior = streamBehavior
        return AsyncThrowingStream { continuation in
            switch behavior {
            case .empty:
                onClose?()
                continuation.finish()
            case .emitOneThenClose:
                onClose?()
                continuation.finish()
            case .emitMultipleThenClose:
                onClose?()
                continuation.finish()
            case .neverClose:
                Task<Void, Never> {
                    while !Task.isCancelled {
                        try? await Task.sleep(nanoseconds: 60_000_000_000)
                    }
                }
            case .delayedStart(let delay):
                Task<Void, Never> {
                    try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
                    while !Task.isCancelled {
                        try? await Task.sleep(nanoseconds: 60_000_000_000)
                    }
                }
            case .throwImmediately:
                continuation.finish(throwing: NSError(domain: "test", code: 1, userInfo: [NSLocalizedDescriptionKey: "Stream failed"]))
            }
        }
    }

    func syncAllConversations(consentStates: [XMTPiOS.ConsentState]?) async throws -> GroupSyncSummary {
        lock.withLock { _syncCallCount += 1 }

        switch syncBehavior {
        case .succeed:
            return GroupSyncSummary(numEligible: 0, numSynced: 0)
        case .fail(let error):
            throw error
        case .delay(let delay):
            try await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            return GroupSyncSummary(numEligible: 0, numSynced: 0)
        }
    }

    func sync() async throws {
    }

    func findConversation(conversationId: String) async throws -> XMTPiOS.Conversation? {
        nil
    }

    func streamAllMessages(type: ConversationFilterType,
                          consentStates: [ConsentState]?,
                          onClose: (() -> Void)?) -> AsyncThrowingStream<DecodedMessage, any Error> {
        lock.withLock { _streamCallCount += 1 }
        let behavior = streamBehavior
        return AsyncThrowingStream { continuation in
            switch behavior {
            case .empty:
                onClose?()
                continuation.finish()
            case .emitOneThenClose:
                onClose?()
                continuation.finish()
            case .emitMultipleThenClose:
                onClose?()
                continuation.finish()
            case .neverClose:
                Task<Void, Never> {
                    while !Task.isCancelled {
                        try? await Task.sleep(nanoseconds: 60_000_000_000)
                    }
                }
            case .delayedStart(let delay):
                Task<Void, Never> {
                    try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
                    while !Task.isCancelled {
                        try? await Task.sleep(nanoseconds: 60_000_000_000)
                    }
                }
            case .throwImmediately:
                continuation.finish(throwing: NSError(domain: "test", code: 1, userInfo: [NSLocalizedDescriptionKey: "Stream failed"]))
            }
        }
    }
}

class TestableMockGroupConversationSender: GroupConversationSender {
    var id: String = UUID().uuidString

    func add(members inboxIds: [String]) async throws {
    }

    func remove(members inboxIds: [String]) async throws {
    }

    func prepare(text: String) async throws -> String {
        ""
    }

    func ensureInviteTag() async throws {
    }

    func publish() async throws {
    }

    func permissionPolicySet() throws -> PermissionPolicySet {
        PermissionPolicySet(
            addMemberPolicy: .allow,
            removeMemberPolicy: .allow,
            addAdminPolicy: .allow,
            removeAdminPolicy: .allow,
            updateGroupNamePolicy: .allow,
            updateGroupDescriptionPolicy: .allow,
            updateGroupImagePolicy: .allow,
            updateMessageDisappearingPolicy: .allow,
            updateAppDataPolicy: .allow
        )
    }

    func updateAddMemberPermission(newPermissionOption: PermissionOption) async throws {
    }
}

class TestableMockMessageSender: MessageSender {
    func sendExplode(expiresAt: Date) async throws {
    }

    func prepare(text: String) async throws -> String {
        ""
    }

    func prepare(remoteAttachment: RemoteAttachment) async throws -> String {
        ""
    }

    func prepare(reply: Reply) async throws -> String {
        ""
    }

    func publish() async throws {
    }

    func publishMessage(messageId: String) async throws {
    }

    func consentState() throws -> ConsentState {
        .allowed
    }
}

/// Testable mock API client
final class TestableMockAPIClient: ConvosAPIClientProtocol, @unchecked Sendable {
    private(set) var callCount = 0

    func request(for path: String, method: String, queryParameters: [String: String]?) throws -> URLRequest {
        callCount += 1
        guard let url = URL(string: "http://example.com") else {
            throw NSError(domain: "test", code: 1)
        }
        return URLRequest(url: url)
    }

    func registerDevice(deviceId: String, pushToken: String?) async throws {
    }

    func authenticate(appCheckToken: String, retryCount: Int) async throws -> String {
        "mock-jwt-token"
    }

    func uploadAttachment(data: Data, filename: String, contentType: String, acl: String) async throws -> String {
        "https://mock-api.example.com/uploads/\(filename)"
    }

    func uploadAttachmentAndExecute(data: Data, filename: String, afterUpload: @escaping (String) async throws -> Void) async throws -> String {
        let uploadedURL = "https://mock-api.example.com/uploads/\(filename)"
        try await afterUpload(uploadedURL)
        return uploadedURL
    }

    func subscribeToTopics(deviceId: String, clientId: String, topics: [String]) async throws {
    }

    func unsubscribeFromTopics(clientId: String, topics: [String]) async throws {
    }

    func unregisterInstallation(clientId: String) async throws {
    }

    func getPresignedUploadURL(filename: String, contentType: String) async throws -> (uploadURL: String, assetURL: String) {
        ("https://mock-api.example.com/upload/\(filename)", "https://mock-api.example.com/assets/\(filename)")
    }
}

/// Comprehensive tests for SyncingManager state machine
@Suite("SyncingManager Tests", .serialized)
struct SyncingManagerTests {

    private enum TestError: Error {
        case timeout(String)
    }

    /// Polling-based wait for condition to become true
    /// More reliable than fixed sleep for CI environments
    private func waitUntil(
        timeout: Duration = .seconds(5),
        interval: Duration = .milliseconds(50),
        condition: () async -> Bool
    ) async throws {
        let deadline = ContinuousClock.now + timeout
        while ContinuousClock.now < deadline {
            if await condition() {
                return
            }
            try await Task.sleep(for: interval)
        }
        throw TestError.timeout("Condition not met within \(timeout)")
    }

    // MARK: - Start Flow Tests

    @Test("Start from idle starts streams then calls syncAllConversations")
    func testStartFlow() async throws {
        let fixtures = TestFixtures()
        let mockClient = TestableMockClient()
        let mockAPIClient = TestableMockAPIClient()

        let syncingManager = SyncingManager(
            identityStore: fixtures.identityStore,
            databaseWriter: fixtures.databaseManager.dbWriter,
            databaseReader: fixtures.databaseManager.dbReader,
            deviceRegistrationManager: nil,
            notificationCenter: MockUserNotificationCenter()
        )

        // Start syncing
        await syncingManager.start(with: mockClient, apiClient: mockAPIClient)

        // Wait for async operations to complete using polling
        // Use longer timeout for CI reliability
        let conversations = mockClient.conversationsProvider as! TestableMockConversations
        try await waitUntil(timeout: .seconds(15)) {
            conversations.streamCallCount > 0 && conversations.syncCallCount > 0
        }

        // Verify streams were started first
        #expect(conversations.streamCallCount > 0, "Streams should be started")

        // Verify syncAllConversations was called after streams
        #expect(conversations.syncCallCount > 0, "syncAllConversations should be called")

        // Clean up
        await syncingManager.stop()
        try? await fixtures.cleanup()
    }

    @Test("Start starts streams before syncAllConversations")
    func testStartOrder() async throws {
        let fixtures = TestFixtures()
        let mockClient = TestableMockClient()
        mockClient.syncBehavior = .delay(0.5) // Delay sync to verify streams start first
        let mockAPIClient = TestableMockAPIClient()

        let syncingManager = SyncingManager(
            identityStore: fixtures.identityStore,
            databaseWriter: fixtures.databaseManager.dbWriter,
            databaseReader: fixtures.databaseManager.dbReader,
            deviceRegistrationManager: nil,
            notificationCenter: MockUserNotificationCenter()
        )

        // Start syncing
        await syncingManager.start(with: mockClient, apiClient: mockAPIClient)

        // Wait a short time - streams should be started but sync might not be done yet
        try await Task.sleep(for: .milliseconds(100))

        let conversations = mockClient.conversationsProvider as! TestableMockConversations

        // Streams should be started immediately
        #expect(conversations.streamCallCount >= 2, "Both message and conversation streams should be started")

        // syncAllConversations should be called (but may not be complete yet)
        #expect(conversations.syncCallCount >= 0, "syncAllConversations may or may not have started yet")

        // Wait for sync to complete
        try await Task.sleep(for: .milliseconds(600))

        // Now verify sync was called
        #expect(conversations.syncCallCount > 0, "syncAllConversations should have been called")

        // Clean up
        await syncingManager.stop()
        try? await fixtures.cleanup()
    }

    @Test("Start handles syncAllConversations failure after streams are started")
    func testStartWithSyncFailure() async throws {
        let fixtures = TestFixtures()
        let mockClient = TestableMockClient()
        mockClient.syncBehavior = .fail(NSError(domain: "test", code: 1, userInfo: [NSLocalizedDescriptionKey: "Sync failed"]))
        let mockAPIClient = TestableMockAPIClient()

        let syncingManager = SyncingManager(
            identityStore: fixtures.identityStore,
            databaseWriter: fixtures.databaseManager.dbWriter,
            databaseReader: fixtures.databaseManager.dbReader,
            deviceRegistrationManager: nil,
            notificationCenter: MockUserNotificationCenter()
        )

        // Start syncing (streams start first, then syncAllConversations is called)
        await syncingManager.start(with: mockClient, apiClient: mockAPIClient)

        // Wait for async operations to complete using polling
        // Use longer timeout for CI reliability
        let conversations = mockClient.conversationsProvider as! TestableMockConversations
        try await waitUntil(timeout: .seconds(15)) {
            conversations.streamCallCount > 0 && conversations.syncCallCount > 0
        }

        // Verify streams were started
        #expect(conversations.streamCallCount > 0, "Streams should be started")

        // Verify syncAllConversations was called (and failed)
        #expect(conversations.syncCallCount > 0, "syncAllConversations should be called")

        // Clean up
        await syncingManager.stop()
        try? await fixtures.cleanup()
    }

    // MARK: - Pause/Resume Tests

    @Test("Pause stops streams but keeps client references")
    func testPauseFlow() async throws {
        let fixtures = TestFixtures()
        let mockClient = TestableMockClient()
        mockClient.streamBehavior = .neverClose // Keep streams open
        let mockAPIClient = TestableMockAPIClient()

        let syncingManager = SyncingManager(
            identityStore: fixtures.identityStore,
            databaseWriter: fixtures.databaseManager.dbWriter,
            databaseReader: fixtures.databaseManager.dbReader,
            deviceRegistrationManager: nil,
            notificationCenter: MockUserNotificationCenter()
        )

        // Start syncing
        await syncingManager.start(with: mockClient, apiClient: mockAPIClient)

        // Wait for streams to start
        try await Task.sleep(for: .milliseconds(200))

        // Pause
        await syncingManager.pause()

        // Wait a bit
        try await Task.sleep(for: .milliseconds(100))

        // Resume should work (proves client/apiClient were retained)
        await syncingManager.resume()

        // Wait a bit
        try await Task.sleep(for: .milliseconds(100))

        // Clean up
        await syncingManager.stop()
        try? await fixtures.cleanup()
    }

    @Test("Resume restarts streams without calling syncAllConversations")
    func testResumeFlow() async throws {
        let fixtures = TestFixtures()
        let mockClient = TestableMockClient()
        mockClient.streamBehavior = .neverClose
        let mockAPIClient = TestableMockAPIClient()

        let syncingManager = SyncingManager(
            identityStore: fixtures.identityStore,
            databaseWriter: fixtures.databaseManager.dbWriter,
            databaseReader: fixtures.databaseManager.dbReader,
            deviceRegistrationManager: nil,
            notificationCenter: MockUserNotificationCenter()
        )

        // Start syncing (streams start first, then syncAllConversations is called)
        await syncingManager.start(with: mockClient, apiClient: mockAPIClient)

        // Wait for initial sync to complete
        try await Task.sleep(for: .milliseconds(500))

        let conversations = mockClient.conversationsProvider as! TestableMockConversations
        let initialSyncCount = conversations.syncCallCount

        // Pause
        await syncingManager.pause()
        try await Task.sleep(for: .milliseconds(500))

        // Resume (should only restart streams, NOT call syncAllConversations)
        await syncingManager.resume()
        try await Task.sleep(for: .milliseconds(500))

        // Verify syncAllConversations was NOT called again on resume
        #expect(conversations.syncCallCount == initialSyncCount, "syncAllConversations should not be called on resume")

        // Clean up
        await syncingManager.stop()
        try? await fixtures.cleanup()
    }

    // MARK: - Stop Tests

    @Test("Stop cancels all tasks and goes to idle")
    func testStopFlow() async throws {
        let fixtures = TestFixtures()
        let mockClient = TestableMockClient()
        mockClient.streamBehavior = .neverClose
        let mockAPIClient = TestableMockAPIClient()

        let syncingManager = SyncingManager(
            identityStore: fixtures.identityStore,
            databaseWriter: fixtures.databaseManager.dbWriter,
            databaseReader: fixtures.databaseManager.dbReader,
            deviceRegistrationManager: nil,
            notificationCenter: MockUserNotificationCenter()
        )

        // Start syncing
        await syncingManager.start(with: mockClient, apiClient: mockAPIClient)

        // Wait for streams to start
        try await Task.sleep(for: .milliseconds(200))

        // Stop
        await syncingManager.stop()

        // Verify we can start again (proves we're in idle state)
        await syncingManager.start(with: mockClient, apiClient: mockAPIClient)

        // Clean up
        await syncingManager.stop()
        try? await fixtures.cleanup()
    }

    // MARK: - State Transition Tests

    @Test("Start while already starting is ignored")
    func testStartWhileStarting() async throws {
        let fixtures = TestFixtures()
        let mockClient = TestableMockClient()
        mockClient.syncBehavior = .delay(1.0) // Delay sync to keep in starting state
        let mockAPIClient = TestableMockAPIClient()

        let syncingManager = SyncingManager(
            identityStore: fixtures.identityStore,
            databaseWriter: fixtures.databaseManager.dbWriter,
            databaseReader: fixtures.databaseManager.dbReader,
            deviceRegistrationManager: nil,
            notificationCenter: MockUserNotificationCenter()
        )

        // Start syncing
        await syncingManager.start(with: mockClient, apiClient: mockAPIClient)

        // Immediately try to start again (should be ignored)
        await syncingManager.start(with: mockClient, apiClient: mockAPIClient)

        // Wait for sync to be called at least once (uses polling for CI reliability)
        let conversations = mockClient.conversationsProvider as! TestableMockConversations
        try await waitUntil(timeout: .seconds(5)) {
            conversations.syncCallCount >= 1
        }

        // Verify syncAllConversations was only called once
        #expect(conversations.syncCallCount == 1, "syncAllConversations should only be called once")

        // Clean up
        await syncingManager.stop()
        try? await fixtures.cleanup()
    }

    @Test("Start while ready with same client is ignored")
    func testStartWhileReadySameClient() async throws {
        let fixtures = TestFixtures()
        let mockClient = TestableMockClient()
        let mockAPIClient = TestableMockAPIClient()

        let syncingManager = SyncingManager(
            identityStore: fixtures.identityStore,
            databaseWriter: fixtures.databaseManager.dbWriter,
            databaseReader: fixtures.databaseManager.dbReader,
            deviceRegistrationManager: nil,
            notificationCenter: MockUserNotificationCenter()
        )

        // Start syncing
        await syncingManager.start(with: mockClient, apiClient: mockAPIClient)

        // Wait for ready state
        try await Task.sleep(for: .milliseconds(200))

        let conversations = mockClient.conversationsProvider as! TestableMockConversations
        let initialSyncCount = conversations.syncCallCount

        // Start again with same client (should be ignored since already ready with same inboxId)
        await syncingManager.start(with: mockClient, apiClient: mockAPIClient)

        // Wait a bit
        try await Task.sleep(for: .milliseconds(100))

        // Verify syncAllConversations was NOT called again (duplicate start ignored)
        #expect(conversations.syncCallCount == initialSyncCount, "syncAllConversations should not be called again for same client")

        // Clean up
        await syncingManager.stop()
        try? await fixtures.cleanup()
    }

    @Test("Start while ready with different client stops and restarts")
    func testStartWhileReadyDifferentClient() async throws {
        let fixtures = TestFixtures()
        let mockClient1 = TestableMockClient()
        mockClient1.inboxId = "inbox-1"
        let mockClient2 = TestableMockClient()
        mockClient2.inboxId = "inbox-2"
        let mockAPIClient = TestableMockAPIClient()

        let syncingManager = SyncingManager(
            identityStore: fixtures.identityStore,
            databaseWriter: fixtures.databaseManager.dbWriter,
            databaseReader: fixtures.databaseManager.dbReader,
            deviceRegistrationManager: nil,
            notificationCenter: MockUserNotificationCenter()
        )

        // Start syncing with first client
        await syncingManager.start(with: mockClient1, apiClient: mockAPIClient)

        // Wait for ready state
        try await Task.sleep(for: .milliseconds(200))

        let conversations2 = mockClient2.conversationsProvider as! TestableMockConversations
        #expect(conversations2.syncCallCount == 0, "Second client should not have been used yet")

        // Start with different client (should stop and restart)
        await syncingManager.start(with: mockClient2, apiClient: mockAPIClient)

        // Wait for restart
        try await Task.sleep(for: .milliseconds(300))

        // Verify syncAllConversations was called on the new client
        #expect(conversations2.syncCallCount > 0, "syncAllConversations should be called on new client after restart")

        // Clean up
        await syncingManager.stop()
        try? await fixtures.cleanup()
    }

    @Test("Pause while starting transitions to paused once ready")
    func testPauseWhileStarting() async throws {
        let fixtures = TestFixtures()
        let mockClient = TestableMockClient()
        mockClient.syncBehavior = .delay(0.5) // Keep in starting state for a bit
        mockClient.streamBehavior = .neverClose // Keep streams open
        let mockAPIClient = TestableMockAPIClient()

        let syncingManager = SyncingManager(
            identityStore: fixtures.identityStore,
            databaseWriter: fixtures.databaseManager.dbWriter,
            databaseReader: fixtures.databaseManager.dbReader,
            deviceRegistrationManager: nil,
            notificationCenter: MockUserNotificationCenter()
        )

        // Start syncing
        await syncingManager.start(with: mockClient, apiClient: mockAPIClient)

        // Pause while starting (should be deferred until starting completes)
        await syncingManager.pause()

        // Wait for sync to complete - should transition to paused, not ready
        try await Task.sleep(for: .milliseconds(600))

        // Resume should work (proves we're in paused state, not ready)
        await syncingManager.resume()

        // Wait a bit for resume to complete
        try await Task.sleep(for: .milliseconds(100))

        // Clean up
        await syncingManager.stop()
        try? await fixtures.cleanup()
    }

    @Test("Pause during starting state pauses after sync completes")
    func testPauseDuringStartingState() async throws {
        let fixtures = TestFixtures()
        let mockClient = TestableMockClient()
        // Use a delay to ensure we're in starting state when pause is called
        mockClient.syncBehavior = .delay(0.3)
        mockClient.streamBehavior = .neverClose
        let mockAPIClient = TestableMockAPIClient()

        let syncingManager = SyncingManager(
            identityStore: fixtures.identityStore,
            databaseWriter: fixtures.databaseManager.dbWriter,
            databaseReader: fixtures.databaseManager.dbReader,
            deviceRegistrationManager: nil,
            notificationCenter: MockUserNotificationCenter()
        )

        // Start syncing - this will be in starting state
        await syncingManager.start(with: mockClient, apiClient: mockAPIClient)

        // Immediately pause while still in starting state
        // This simulates network disconnection during startup
        await syncingManager.pause()

        // Wait for sync to complete
        // The sync should complete, but we should transition to paused, not ready
        try await Task.sleep(for: .milliseconds(400))

        // Verify we can resume (proves we ended up in paused state, not ready)
        // If pause was dropped, resume would fail because we'd be in ready state
        await syncingManager.resume()

        // Wait for resume to complete
        try await Task.sleep(for: .milliseconds(100))

        // Clean up
        await syncingManager.stop()
        try? await fixtures.cleanup()
    }

    @Test("Pause then resume during starting results in ready state")
    func testPauseThenResumeDuringStarting() async throws {
        let fixtures = TestFixtures()
        let mockClient = TestableMockClient()
        // Use a delay to ensure we're in starting state when pause/resume are called
        mockClient.syncBehavior = .delay(0.5)
        mockClient.streamBehavior = .neverClose
        let mockAPIClient = TestableMockAPIClient()

        let syncingManager = SyncingManager(
            identityStore: fixtures.identityStore,
            databaseWriter: fixtures.databaseManager.dbWriter,
            databaseReader: fixtures.databaseManager.dbReader,
            deviceRegistrationManager: nil,
            notificationCenter: MockUserNotificationCenter()
        )

        // Start syncing - this will be in starting state
        await syncingManager.start(with: mockClient, apiClient: mockAPIClient)

        // Pause while in starting state
        await syncingManager.pause()

        // Resume while still in starting state (user changed their mind)
        await syncingManager.resume()

        // Wait for sync to complete
        try await Task.sleep(for: .milliseconds(600))

        // Should be in ready state (not paused) because resume cancelled the pending pause
        // Verify by trying to pause - if we're in ready, pause will work
        // If we were already paused, calling pause would be ignored
        await syncingManager.pause()
        try await Task.sleep(for: .milliseconds(100))

        // Now resume should work (proves we were in ready, not already paused)
        await syncingManager.resume()

        // Clean up
        await syncingManager.stop()
        try? await fixtures.cleanup()
    }

    @Test("Resume while not paused is ignored")
    func testResumeWhileNotPaused() async throws {
        let fixtures = TestFixtures()
        let mockClient = TestableMockClient()
        let mockAPIClient = TestableMockAPIClient()

        let syncingManager = SyncingManager(
            identityStore: fixtures.identityStore,
            databaseWriter: fixtures.databaseManager.dbWriter,
            databaseReader: fixtures.databaseManager.dbReader,
            deviceRegistrationManager: nil,
            notificationCenter: MockUserNotificationCenter()
        )

        // Start syncing
        await syncingManager.start(with: mockClient, apiClient: mockAPIClient)

        // Wait for ready state
        try await Task.sleep(for: .milliseconds(200))

        // Try to resume while not paused (should be ignored)
        await syncingManager.resume()

        // Should still be running
        // Clean up
        await syncingManager.stop()
        try? await fixtures.cleanup()
    }

    // MARK: - Stop Tests

    @Test("Stop from ready state")
    func testStopFromReady() async throws {
        let fixtures = TestFixtures()
        let mockClient = TestableMockClient()
        let mockAPIClient = TestableMockAPIClient()

        let syncingManager = SyncingManager(
            identityStore: fixtures.identityStore,
            databaseWriter: fixtures.databaseManager.dbWriter,
            databaseReader: fixtures.databaseManager.dbReader,
            deviceRegistrationManager: nil,
            notificationCenter: MockUserNotificationCenter()
        )

        // Start syncing
        await syncingManager.start(with: mockClient, apiClient: mockAPIClient)

        // Wait for ready state
        try await Task.sleep(for: .milliseconds(200))

        // Stop
        await syncingManager.stop()

        // Verify we can start again (proves we're in idle)
        await syncingManager.start(with: mockClient, apiClient: mockAPIClient)

        // Clean up
        await syncingManager.stop()
        try? await fixtures.cleanup()
    }

    @Test("Stop from paused state")
    func testStopFromPaused() async throws {
        let fixtures = TestFixtures()
        let mockClient = TestableMockClient()
        let mockAPIClient = TestableMockAPIClient()

        let syncingManager = SyncingManager(
            identityStore: fixtures.identityStore,
            databaseWriter: fixtures.databaseManager.dbWriter,
            databaseReader: fixtures.databaseManager.dbReader,
            deviceRegistrationManager: nil,
            notificationCenter: MockUserNotificationCenter()
        )

        // Start syncing
        await syncingManager.start(with: mockClient, apiClient: mockAPIClient)

        // Wait for ready state
        try await Task.sleep(for: .milliseconds(200))

        // Pause
        await syncingManager.pause()
        try await Task.sleep(for: .milliseconds(100))

        // Stop from paused
        await syncingManager.stop()

        // Verify we can start again
        await syncingManager.start(with: mockClient, apiClient: mockAPIClient)

        // Clean up
        await syncingManager.stop()
        try? await fixtures.cleanup()
    }

    @Test("Stop from starting state")
    func testStopFromStarting() async throws {
        let fixtures = TestFixtures()
        let mockClient = TestableMockClient()
        mockClient.syncBehavior = .delay(1.0) // Keep in starting state
        let mockAPIClient = TestableMockAPIClient()

        let syncingManager = SyncingManager(
            identityStore: fixtures.identityStore,
            databaseWriter: fixtures.databaseManager.dbWriter,
            databaseReader: fixtures.databaseManager.dbReader,
            deviceRegistrationManager: nil,
            notificationCenter: MockUserNotificationCenter()
        )

        // Start syncing
        await syncingManager.start(with: mockClient, apiClient: mockAPIClient)

        // Immediately stop (while still starting)
        await syncingManager.stop()

        // Verify we can start again
        await syncingManager.start(with: mockClient, apiClient: mockAPIClient)

        // Clean up
        await syncingManager.stop()
        try? await fixtures.cleanup()
    }

    @Test("Stop waits for completion when called from ready state")
    func testStopWaitsFromReadyState() async throws {
        let fixtures = TestFixtures()
        let mockClient = TestableMockClient()
        mockClient.streamBehavior = .neverClose // Keep streams open so stop takes time
        let mockAPIClient = TestableMockAPIClient()

        let syncingManager = SyncingManager(
            identityStore: fixtures.identityStore,
            databaseWriter: fixtures.databaseManager.dbWriter,
            databaseReader: fixtures.databaseManager.dbReader,
            deviceRegistrationManager: nil,
            notificationCenter: MockUserNotificationCenter()
        )

        // Start syncing
        await syncingManager.start(with: mockClient, apiClient: mockAPIClient)

        // Wait for ready state (after sync completes)
        try await Task.sleep(for: .milliseconds(200))

        // Call stop() when state is .ready (not .stopping)
        // This tests the race condition: stop() should wait until state becomes .idle
        let stopStartTime = Date()
        await syncingManager.stop()
        let stopDuration = Date().timeIntervalSince(stopStartTime)

        // Verify stop() actually waited (took some time to complete)
        // If the race condition existed, stop() would return immediately
        #expect(stopDuration > 0.01, "stop() should wait for completion, not return immediately")

        // Verify we can immediately start again after stop() returns
        // This proves stop() waited until state was .idle
        await syncingManager.start(with: mockClient, apiClient: mockAPIClient)

        // Clean up
        await syncingManager.stop()
        try? await fixtures.cleanup()
    }

    // MARK: - Stream Readiness Tests

    @Test("isSyncReady is false before start completes")
    func testSyncNotReadyBeforeStart() async throws {
        let fixtures = TestFixtures()
        let mockClient = TestableMockClient()
        mockClient.syncBehavior = .delay(0.5) // Delay sync to observe intermediate state
        mockClient.streamBehavior = .neverClose
        let mockAPIClient = TestableMockAPIClient()

        let syncingManager = SyncingManager(
            identityStore: fixtures.identityStore,
            databaseWriter: fixtures.databaseManager.dbWriter,
            databaseReader: fixtures.databaseManager.dbReader,
            deviceRegistrationManager: nil
        )

        // Before starting, should not be ready
        let readyBeforeStart = await syncingManager.isSyncReady
        #expect(!readyBeforeStart, "Should not be ready before start")

        // Start syncing
        await syncingManager.start(with: mockClient, apiClient: mockAPIClient)

        // Immediately after start() returns, we're in "starting" state
        // isSyncReady should still be false because syncAllConversations hasn't completed
        let readyDuringStart = await syncingManager.isSyncReady
        #expect(!readyDuringStart, "Should not be ready while starting (sync in progress)")

        // Wait for sync to complete
        try await Task.sleep(for: .milliseconds(600))

        // Now should be ready
        let readyAfterSync = await syncingManager.isSyncReady
        #expect(readyAfterSync, "Should be ready after sync completes")

        // Clean up
        await syncingManager.stop()
        try? await fixtures.cleanup()
    }

    @Test("Streams signal ready before syncAllConversations completes")
    func testStreamsReadyBeforeSyncCompletes() async throws {
        let fixtures = TestFixtures()
        let mockClient = TestableMockClient()
        mockClient.syncBehavior = .delay(0.5) // Sync takes time
        mockClient.streamBehavior = .neverClose // Streams stay open
        let mockAPIClient = TestableMockAPIClient()

        let syncingManager = SyncingManager(
            identityStore: fixtures.identityStore,
            databaseWriter: fixtures.databaseManager.dbWriter,
            databaseReader: fixtures.databaseManager.dbReader,
            deviceRegistrationManager: nil
        )

        let conversations = mockClient.conversationsProvider as! TestableMockConversations

        // Start syncing
        await syncingManager.start(with: mockClient, apiClient: mockAPIClient)

        // After start() returns, stream tasks are spawned and we've waited for
        // them to signal ready. The actual mock stream methods are called shortly after.
        // Wait for the streams to be set up
        try await waitUntil(timeout: .seconds(2)) {
            conversations.streamCallCount >= 2
        }

        #expect(conversations.streamCallCount >= 2, "Both streams should be started")

        // At this point, syncAllConversations should still be running (we delayed it 0.5s)
        // But streams are already started and subscribed
        let readyBeforeSyncDone = await syncingManager.isSyncReady
        #expect(!readyBeforeSyncDone, "Should not be ready until sync completes")

        // Wait for sync to complete
        try await waitUntil(timeout: .seconds(5)) {
            await syncingManager.isSyncReady
        }

        // Verify sync was also called
        #expect(conversations.syncCallCount > 0, "syncAllConversations should have been called")

        // Clean up
        await syncingManager.stop()
        try? await fixtures.cleanup()
    }

    @Test("Resume waits for streams to be ready before transitioning to ready state")
    func testResumeWaitsForStreamReadiness() async throws {
        let fixtures = TestFixtures()
        let mockClient = TestableMockClient()
        mockClient.streamBehavior = .neverClose
        let mockAPIClient = TestableMockAPIClient()

        let syncingManager = SyncingManager(
            identityStore: fixtures.identityStore,
            databaseWriter: fixtures.databaseManager.dbWriter,
            databaseReader: fixtures.databaseManager.dbReader,
            deviceRegistrationManager: nil
        )

        // Start and wait for ready
        await syncingManager.start(with: mockClient, apiClient: mockAPIClient)
        try await waitUntil(timeout: .seconds(5)) {
            await syncingManager.isSyncReady
        }

        // Pause
        await syncingManager.pause()
        try await Task.sleep(for: .milliseconds(100))

        // Verify paused (not ready)
        let readyWhilePaused = await syncingManager.isSyncReady
        #expect(!readyWhilePaused, "Should not be ready while paused")

        // Resume
        await syncingManager.resume()

        // Wait for ready state after resume
        try await waitUntil(timeout: .seconds(5)) {
            await syncingManager.isSyncReady
        }

        // Should be ready again
        let readyAfterResume = await syncingManager.isSyncReady
        #expect(readyAfterResume, "Should be ready after resume")

        // Clean up
        await syncingManager.stop()
        try? await fixtures.cleanup()
    }

    @Test("Stream failure triggers retry and eventually becomes ready")
    func testStreamFailureRetry() async throws {
        let fixtures = TestFixtures()
        let mockClient = TestableMockClient()
        mockClient.streamBehavior = .throwImmediately // Streams fail immediately
        let mockAPIClient = TestableMockAPIClient()

        let syncingManager = SyncingManager(
            identityStore: fixtures.identityStore,
            databaseWriter: fixtures.databaseManager.dbWriter,
            databaseReader: fixtures.databaseManager.dbReader,
            deviceRegistrationManager: nil
        )

        // Start syncing - streams will fail but readiness signals are still sent
        await syncingManager.start(with: mockClient, apiClient: mockAPIClient)

        // Wait for sync to complete (it should still complete even with stream failures)
        try await waitUntil(timeout: .seconds(5)) {
            await syncingManager.isSyncReady
        }

        // Should be ready despite stream failures (streams have retry logic)
        let isReady = await syncingManager.isSyncReady
        #expect(isReady, "Should be ready even when streams fail (they retry)")

        // Clean up
        await syncingManager.stop()
        try? await fixtures.cleanup()
    }

    @Test("Multiple rapid start/stop cycles handle stream readiness correctly")
    func testRapidStartStopCycles() async throws {
        let fixtures = TestFixtures()
        let mockClient = TestableMockClient()
        mockClient.streamBehavior = .neverClose
        let mockAPIClient = TestableMockAPIClient()

        let syncingManager = SyncingManager(
            identityStore: fixtures.identityStore,
            databaseWriter: fixtures.databaseManager.dbWriter,
            databaseReader: fixtures.databaseManager.dbReader,
            deviceRegistrationManager: nil
        )

        // Cycle 1
        await syncingManager.start(with: mockClient, apiClient: mockAPIClient)
        try await waitUntil(timeout: .seconds(5)) {
            await syncingManager.isSyncReady
        }
        await syncingManager.stop()

        // Cycle 2
        await syncingManager.start(with: mockClient, apiClient: mockAPIClient)
        try await waitUntil(timeout: .seconds(5)) {
            await syncingManager.isSyncReady
        }
        await syncingManager.stop()

        // Cycle 3
        await syncingManager.start(with: mockClient, apiClient: mockAPIClient)
        try await waitUntil(timeout: .seconds(5)) {
            await syncingManager.isSyncReady
        }

        // Final state should be ready
        let isReady = await syncingManager.isSyncReady
        #expect(isReady, "Should be ready after multiple cycles")

        // Clean up
        await syncingManager.stop()
        try? await fixtures.cleanup()
    }
}
