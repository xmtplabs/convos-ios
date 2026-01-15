@testable import ConvosCore
import Foundation
import GRDB
import Testing
import XMTPiOS

// MARK: - Test Helpers

private let testAppLifecycle = MockAppLifecycleProvider()

/// Comprehensive tests for InboxStateMachine
///
/// Tests cover:
/// - Registration flow (idle → registering → authenticating → ready)
/// - Authorization flow (idle → authorizing → authenticating → ready)
/// - State transitions and error handling
/// - Delete flow (ready → deleting → stopping → idle)
/// - Stop flow (ready → stopping → idle)
/// - Database cleanup on deletion
/// - Keychain management
@Suite("InboxStateMachine Tests", .serialized)
struct InboxStateMachineTests {
    // MARK: - Registration Tests

    @Test("Register creates new client and reaches ready state")
    func testRegisterFlow() async throws {
        let fixtures = TestFixtures()

        let clientId = ClientId.generate().value
        let mockSync = MockSyncingManager()
        let mockInvites = MockInvitesRepository()
        let networkMonitor = NetworkMonitor()

        let stateMachine = InboxStateMachine(
            clientId: clientId,
            identityStore: fixtures.identityStore,
            invitesRepository: mockInvites,
            databaseWriter: fixtures.databaseManager.dbWriter,
            syncingManager: mockSync,
            networkMonitor: networkMonitor,
            overrideJWTToken: "test-jwt-token",  // Skip backend auth for tests
            environment: .tests,
            appLifecycle: testAppLifecycle
        )

        // Start in idle state
        let initialState = await stateMachine.state
        #expect(initialState.clientId == clientId)

        // Register
        await stateMachine.register(clientId: clientId)

        // Wait for ready state (with timeout)
        let state = try await waitForState(stateMachine, timeout: 30) { state in
            if case .ready = state { return true }
            if case .error = state { return true }
            return false
        }

        guard case .ready(_, let result) = state else {
            if case .error(_, let error) = state {
                Issue.record("Registration failed: \(error)")
            }
            Issue.record("Did not reach ready state")
            return
        }

        #expect(await mockSync.isStarted, "Syncing should be started")
        #expect(await mockSync.startCallCount == 1)

        // Verify identity was saved
        let savedIdentity = try await fixtures.identityStore.identity(for: result.client.inboxId)
        #expect(savedIdentity.clientId == clientId)

        // Clean up
        try? result.client.deleteLocalDatabase()
        try? await fixtures.cleanup()
    }

    @Test("Register saves to both keychain and database")
    func testRegisterSavesToKeychainAndDatabase() async throws {
        let fixtures = TestFixtures()

        let clientId = ClientId.generate().value
        let mockInvites = MockInvitesRepository()
        let networkMonitor = NetworkMonitor()

        let stateMachine = InboxStateMachine(
            clientId: clientId,
            identityStore: fixtures.identityStore,
            invitesRepository: mockInvites,
            databaseWriter: fixtures.databaseManager.dbWriter,
            syncingManager: nil,
            networkMonitor: networkMonitor,
            overrideJWTToken: "test-jwt-token",
            environment: .tests,
            appLifecycle: testAppLifecycle
        )

        await stateMachine.register(clientId: clientId)

        // Wait for ready state
        var result: InboxReadyResult?
        for await state in await stateMachine.stateSequence {
            switch state {
            case .ready(_, let readyResult):
                result = readyResult
                case .error(_, let error):
                Issue.record("Registration failed: \(error)")
            default:
                continue
            }

            if result != nil {
                break
            }
        }

        #expect(result != nil, "Should reach ready state")

        // Verify identity was saved to keychain
        let savedIdentity = try await fixtures.identityStore.identity(for: result!.client.inboxId)
        #expect(savedIdentity.clientId == clientId)

        // Verify saved to database
        let dbInboxes = try await fixtures.databaseManager.dbReader.read { db in
            try DBInbox.fetchAll(db)
        }
        #expect(dbInboxes.count == 1, "Should save to database")
        #expect(dbInboxes.first?.clientId == clientId)

        // Clean up
        try? result?.client.deleteLocalDatabase()
        try? await fixtures.cleanup()
    }

    // MARK: - Authorization Tests

    @Test("Authorize with existing identity reaches ready state")
    func testAuthorizeFlow() async throws {
        let fixtures = TestFixtures()

        // Create a client and save identity first
        let (client, clientId, _) = try await fixtures.createClient()

        let mockSync = MockSyncingManager()
        let mockInvites = MockInvitesRepository()
        let networkMonitor = NetworkMonitor()

        let stateMachine = InboxStateMachine(
            clientId: clientId,
            identityStore: fixtures.identityStore,
            invitesRepository: mockInvites,
            databaseWriter: fixtures.databaseManager.dbWriter,
            syncingManager: mockSync,
            networkMonitor: networkMonitor,
            overrideJWTToken: "test-jwt-token",  // Skip backend auth for tests
            environment: .tests,
            appLifecycle: testAppLifecycle
        )

        // Authorize with the existing inbox
        await stateMachine.authorize(inboxId: client.inboxId, clientId: clientId)

        // Wait for ready state
        var result: InboxReadyResult?
        for await state in await stateMachine.stateSequence {
            switch state {
            case .ready(_, let readyResult):
                result = readyResult
                case .error(_, let error):
                Issue.record("Authorization failed: \(error)")
            default:
                continue
            }

            if result != nil {
                break
            }
        }

        #expect(result != nil, "Should reach ready state")
        #expect(result?.client.inboxId == client.inboxId)
        #expect(await mockSync.isStarted, "Syncing should be started")

        // Clean up
        try? client.deleteLocalDatabase()
        try? await fixtures.cleanup()
    }

    @Test("Authorize with mismatched clientId fails")
    func testAuthorizeMismatchedClientId() async throws {
        let fixtures = TestFixtures()

        // Create a client and save identity
        let (client, _, _) = try await fixtures.createClient()

        let wrongClientId = ClientId.generate().value
        let mockInvites = MockInvitesRepository()
        let networkMonitor = NetworkMonitor()

        let stateMachine = InboxStateMachine(
            clientId: wrongClientId,
            identityStore: fixtures.identityStore,
            invitesRepository: mockInvites,
            databaseWriter: fixtures.databaseManager.dbWriter,
            syncingManager: nil,
            networkMonitor: networkMonitor,
            environment: .tests,
            appLifecycle: testAppLifecycle
        )

        // Try to authorize with wrong clientId
        await stateMachine.authorize(inboxId: client.inboxId, clientId: wrongClientId)

        // Wait for error state
        var errorOccurred = false
        for await state in await stateMachine.stateSequence {
            switch state {
            case .error:
                errorOccurred = true
                case .ready:
                Issue.record("Should not reach ready state with mismatched clientId")
            default:
                continue
            }

            if errorOccurred {
                break
            }
        }

        #expect(errorOccurred, "Should error with mismatched clientId")

        // Clean up
        try? client.deleteLocalDatabase()
        try? await fixtures.cleanup()
    }

    // MARK: - Stop Tests

    @Test("Stop transitions from ready to idle")
    func testStopFlow() async throws {
        let fixtures = TestFixtures()

        let clientId = ClientId.generate().value
        let mockSync = MockSyncingManager()
        let mockInvites = MockInvitesRepository()
        let networkMonitor = NetworkMonitor()

        let stateMachine = InboxStateMachine(
            clientId: clientId,
            identityStore: fixtures.identityStore,
            invitesRepository: mockInvites,
            databaseWriter: fixtures.databaseManager.dbWriter,
            syncingManager: mockSync,
            networkMonitor: networkMonitor,
            overrideJWTToken: "test-jwt-token",  // Skip backend auth for tests
            environment: .tests,
            appLifecycle: testAppLifecycle
        )

        // Register and wait for ready
        await stateMachine.register(clientId: clientId)

        var client: (any XMTPClientProvider)?
        for await state in await stateMachine.stateSequence {
            if case .ready(_, let result) = state {
                client = result.client
                break
            }
        }

        defer {
            try? client?.deleteLocalDatabase()
        }

        #expect(await mockSync.isStarted, "Syncing should be started")

        // Stop
        await stateMachine.stop()

        // Wait for idle state
        var stoppedSuccessfully = false
        for await state in await stateMachine.stateSequence {
            if case .idle = state {
                stoppedSuccessfully = true
                break
            }
        }

        #expect(stoppedSuccessfully, "Should return to idle state")

        let syncIsStarted = await mockSync.isStarted
        let stopCount = await mockSync.stopCallCount
        #expect(!syncIsStarted, "Syncing should be stopped")
        #expect(stopCount == 1)

        // Verify identity still exists (stop doesn't delete)
        let identities = try await fixtures.identityStore.loadAll()
        #expect(identities.count == 1)

        // Clean up
        try? client?.deleteLocalDatabase()
        try? await fixtures.cleanup()
    }

    // MARK: - Delete Tests

    @Test("Delete removes all data and returns to idle")
    func testDeleteFlow() async throws {
        let fixtures = TestFixtures()

        let clientId = ClientId.generate().value
        let mockSync = MockSyncingManager()
        let mockInvites = MockInvitesRepository()
        let networkMonitor = NetworkMonitor()

        let stateMachine = InboxStateMachine(
            clientId: clientId,
            identityStore: fixtures.identityStore,
            invitesRepository: mockInvites,
            databaseWriter: fixtures.databaseManager.dbWriter,
            syncingManager: mockSync,
            networkMonitor: networkMonitor,
            overrideJWTToken: "test-jwt-token",  // Skip backend auth for tests
            environment: .tests,
            appLifecycle: testAppLifecycle
        )

        // Register and wait for ready
        await stateMachine.register(clientId: clientId)

        var inboxId: String?
        for await state in await stateMachine.stateSequence {
            if case .ready(_, let result) = state {
                inboxId = result.client.inboxId
                break
            }
        }

        #expect(inboxId != nil)

        // Verify identity exists before delete
        let identityBeforeDelete = try? await fixtures.identityStore.identity(for: inboxId!)
        #expect(identityBeforeDelete != nil)

        // Delete
        await stateMachine.stopAndDelete()

        // Wait for idle state
        var deletedSuccessfully = false
        for await state in await stateMachine.stateSequence {
            if case .idle = state {
                deletedSuccessfully = true
                break
            }
        }

        #expect(deletedSuccessfully, "Should return to idle state")

        let syncIsStarted = await mockSync.isStarted
        #expect(!syncIsStarted, "Syncing should be stopped")

        // Verify identity was deleted
        do {
            _ = try await fixtures.identityStore.identity(for: inboxId!)
            Issue.record("Identity should have been deleted")
        } catch {
            // Expected - identity should not exist
        }

        // Verify database record was deleted
        let dbInboxes = try await fixtures.databaseManager.dbReader.read { db in
            try DBInbox.filter(DBInbox.Columns.clientId == clientId).fetchAll(db)
        }
        #expect(dbInboxes.isEmpty, "Database record should be deleted")

        // Clean up (database already cleaned by delete flow)
        try? await fixtures.cleanup()
    }

    @Test("Delete from error state cleans up properly")
    func testDeleteFromErrorState() async throws {
        let fixtures = TestFixtures()

        let clientId = ClientId.generate().value
        let mockSync = MockSyncingManager()
        let mockInvites = MockInvitesRepository()
        let networkMonitor = NetworkMonitor()

        let stateMachine = InboxStateMachine(
            clientId: clientId,
            identityStore: fixtures.identityStore,
            invitesRepository: mockInvites,
            databaseWriter: fixtures.databaseManager.dbWriter,
            syncingManager: mockSync,
            networkMonitor: networkMonitor,
            overrideJWTToken: "test-jwt-token",  // Skip backend auth for tests
            environment: .tests,
            appLifecycle: testAppLifecycle
        )

        // Try to authorize with non-existent inboxId to trigger error
        let nonExistentInboxId = "0000000000000000000000000000000000000000000000000000000000000000"
        await stateMachine.authorize(inboxId: nonExistentInboxId, clientId: clientId)

        // Wait for error state
        var errorOccurred = false
        for await state in await stateMachine.stateSequence {
            if case .error = state {
                errorOccurred = true
                break
            }
        }

        #expect(errorOccurred, "Should reach error state")

        // Delete from error state
        await stateMachine.stopAndDelete()

        // Wait for idle state
        var deletedSuccessfully = false
        for await state in await stateMachine.stateSequence {
            if case .idle = state {
                deletedSuccessfully = true
                break
            }
        }

        #expect(deletedSuccessfully, "Should return to idle state after delete from error")

        // Clean up
        try? await fixtures.cleanup()
    }

    // MARK: - State Observation Tests

    @Test("State sequence emits all state changes")
    func testStateSequenceEmission() async throws {
        let fixtures = TestFixtures()

        let clientId = ClientId.generate().value
        let mockInvites = MockInvitesRepository()
        let networkMonitor = NetworkMonitor()

        let stateMachine = InboxStateMachine(
            clientId: clientId,
            identityStore: fixtures.identityStore,
            invitesRepository: mockInvites,
            databaseWriter: fixtures.databaseManager.dbWriter,
            syncingManager: nil,
            networkMonitor: networkMonitor,
            environment: .tests,
            appLifecycle: testAppLifecycle
        )

        actor StateCollector {
            var states: [String] = []
            func add(_ state: String) {
                states.append(state)
            }
            func getStates() -> [String] {
                states
            }
        }

        let collector = StateCollector()

        // Observe states in background
        let observerTask = Task {
            for await state in await stateMachine.stateSequence {
                let stateName: String
                switch state {
                case .idle:
                    stateName = "idle"
                case .registering:
                    stateName = "registering"
                case .authenticatingBackend:
                    stateName = "authenticatingBackend"
                case .ready:
                    stateName = "ready"
                case .backgrounded:
                    stateName = "backgrounded"
                case .error:
                    stateName = "error"
                case .authorizing:
                    stateName = "authorizing"
                case .deleting:
                    stateName = "deleting"
                case .stopping:
                    stateName = "stopping"
                }
                await collector.add(stateName)

                if stateName == "ready" {
                    break
                }
            }
        }

        // Register
        await stateMachine.register(clientId: clientId)

        // Wait for observer to finish
        await observerTask.value

        // Verify state progression
        let observedStates = await collector.getStates()
        #expect(observedStates.contains("registering"))
        #expect(observedStates.contains("authenticatingBackend"))
        #expect(observedStates.contains("ready"))

        // Clean up
        let finalState = await stateMachine.state
        if case .ready(_, let result) = finalState {
            try? result.client.deleteLocalDatabase()
        }
        try? await fixtures.cleanup()
    }

    // MARK: - Multiple Action Queue Tests

    @Test("Action queue processes actions sequentially")
    func testActionQueueSequencing() async throws {
        let fixtures = TestFixtures()

        let clientId = ClientId.generate().value
        let mockSync = MockSyncingManager()
        let mockInvites = MockInvitesRepository()
        let networkMonitor = NetworkMonitor()

        let stateMachine = InboxStateMachine(
            clientId: clientId,
            identityStore: fixtures.identityStore,
            invitesRepository: mockInvites,
            databaseWriter: fixtures.databaseManager.dbWriter,
            syncingManager: mockSync,
            networkMonitor: networkMonitor,
            overrideJWTToken: "test-jwt-token",  // Skip backend auth for tests
            environment: .tests,
            appLifecycle: testAppLifecycle
        )

        // Queue register and then stop
        await stateMachine.register(clientId: clientId)

        // Wait for ready, then queue stop
        var client: (any XMTPClientProvider)?
        for await state in await stateMachine.stateSequence {
            if case .ready(_, let result) = state {
                client = result.client
                await stateMachine.stop()
                break
            }
        }

        // Wait for idle after stop
        var stoppedSuccessfully = false
        for await state in await stateMachine.stateSequence {
            if case .idle = state {
                stoppedSuccessfully = true
                break
            }
        }

        #expect(stoppedSuccessfully, "Should process stop after register")

        // Clean up
        try? client?.deleteLocalDatabase()
        try? await fixtures.cleanup()
    }

    // MARK: - Network Disconnection Tests

    @Test("Messages sync after network disconnection and reconnection")
    func testNetworkDisconnectionAndReconnection() async throws {
        let fixtures = TestFixtures()

        // Create mock network monitor starting connected
        let mockNetworkMonitor = MockNetworkMonitor(initialStatus: .connected(.wifi))

        // Setup sender with real messaging service and mock network
        let clientId = ClientId.generate().value
        let mockSync = MockSyncingManager()
        let mockInvites = MockInvitesRepository()

        let stateMachine = InboxStateMachine(
            clientId: clientId,
            identityStore: fixtures.identityStore,
            invitesRepository: mockInvites,
            databaseWriter: fixtures.databaseManager.dbWriter,
            syncingManager: mockSync,
            networkMonitor: mockNetworkMonitor,
            overrideJWTToken: "test-jwt-token",
            environment: .tests,
            appLifecycle: testAppLifecycle
        )

        // Register and wait for ready
        await stateMachine.register(clientId: clientId)

        // Wait for ready state with timeout
        let state = try await waitForState(stateMachine, timeout: 30) { state in
            if case .ready = state { return true }
            if case .error = state { return true }
            return false
        }

        guard case .ready(_, let result) = state else {
            if case .error(_, let error) = state {
                Issue.record("Registration failed: \(error)")
            }
            Issue.record("Did not reach ready state")
            try? await fixtures.cleanup()
            return
        }

        #expect(await mockSync.isStarted, "Sync should be started")

        Log.info("Inbox ready, simulating network disconnection...")

        // Simulate network disconnection
        await mockNetworkMonitor.simulateDisconnection()

        // Wait for pause to take effect
        try await Task.sleep(for: .seconds(1))

        // Verify sync was paused
        let pauseCount = await mockSync.pauseCallCount
        #expect(pauseCount > 0, "SyncingManager should have been paused after disconnection")
        #expect(await mockSync.isPaused, "SyncingManager should be in paused state")

        Log.info("Network disconnected, sync paused. Simulating reconnection...")

        // Simulate network reconnection
        await mockNetworkMonitor.simulateConnection(type: .wifi)

        // Wait for resume to take effect
        try await Task.sleep(for: .seconds(1))

        // Verify sync was resumed
        let resumeCount = await mockSync.resumeCallCount
        #expect(resumeCount > 0, "SyncingManager should have been resumed after reconnection")
        #expect(!(await mockSync.isPaused), "SyncingManager should not be paused after reconnection")

        Log.info("Network reconnected, sync resumed successfully")

        // Clean up
        await stateMachine.stopAndDelete()
        try? result.client.deleteLocalDatabase()
        try? await fixtures.cleanup()
    }

    // MARK: - App Lifecycle Tests

    @Test("App backgrounding pauses sync and app foregrounding resumes sync")
    func testAppBackgroundAndForeground() async throws {
        let fixtures = TestFixtures()

        let clientId = ClientId.generate().value
        let mockSync = MockSyncingManager()
        let mockInvites = MockInvitesRepository()
        let networkMonitor = NetworkMonitor()

        let stateMachine = InboxStateMachine(
            clientId: clientId,
            identityStore: fixtures.identityStore,
            invitesRepository: mockInvites,
            databaseWriter: fixtures.databaseManager.dbWriter,
            syncingManager: mockSync,
            networkMonitor: networkMonitor,
            overrideJWTToken: "test-jwt-token",
            environment: .tests,
            appLifecycle: testAppLifecycle
        )

        // Register and wait for ready
        await stateMachine.register(clientId: clientId)

        // Wait for ready state with timeout
        let state = try await waitForState(stateMachine, timeout: 30) { state in
            if case .ready = state { return true }
            if case .error = state { return true }
            return false
        }

        guard case .ready(_, let result) = state else {
            if case .error(_, let error) = state {
                Issue.record("Registration failed: \(error)")
            }
            Issue.record("Did not reach ready state")
            try? await fixtures.cleanup()
            return
        }

        #expect(await mockSync.isStarted, "Sync should be started")

        Log.info("Inbox ready, simulating app entering background...")

        // Give the notification observer Task time to start listening
        try await Task.sleep(for: .milliseconds(100))

        // Simulate app entering background
        NotificationCenter.default.post(name: testAppLifecycle.didEnterBackgroundNotification, object: nil)

        // Wait for backgrounded state
        let backgroundedState = try await waitForState(stateMachine, timeout: 5) { state in
            if case .backgrounded = state { return true }
            return false
        }

        guard case .backgrounded = backgroundedState else {
            Issue.record("Did not reach backgrounded state")
            try? await fixtures.cleanup()
            return
        }

        // Verify sync was paused
        #expect(await mockSync.isPaused, "SyncingManager should be paused when backgrounded")
        let pauseCount = await mockSync.pauseCallCount
        #expect(pauseCount > 0, "SyncingManager should have been paused")

        Log.info("App backgrounded, sync paused. Simulating app returning to foreground...")

        // Simulate app entering foreground
        NotificationCenter.default.post(name: testAppLifecycle.willEnterForegroundNotification, object: nil)

        // Wait for ready state again
        let foregroundState = try await waitForState(stateMachine, timeout: 5) { state in
            if case .ready = state { return true }
            return false
        }

        guard case .ready = foregroundState else {
            Issue.record("Did not return to ready state")
            try? await fixtures.cleanup()
            return
        }

        // Verify sync was resumed
        let resumeCount = await mockSync.resumeCallCount
        #expect(resumeCount > 0, "SyncingManager should have been resumed after foregrounding")
        #expect(!(await mockSync.isPaused), "SyncingManager should not be paused after foregrounding")

        Log.info("App foregrounded, sync resumed successfully")

        // Clean up
        await stateMachine.stopAndDelete()
        try? result.client.deleteLocalDatabase()
        try? await fixtures.cleanup()
    }

    @Test("State sequence includes backgrounded state")
    func testStateSequenceIncludesBackgrounded() async throws {
        let fixtures = TestFixtures()

        let clientId = ClientId.generate().value
        let mockInvites = MockInvitesRepository()
        let networkMonitor = NetworkMonitor()

        let stateMachine = InboxStateMachine(
            clientId: clientId,
            identityStore: fixtures.identityStore,
            invitesRepository: mockInvites,
            databaseWriter: fixtures.databaseManager.dbWriter,
            syncingManager: nil,
            networkMonitor: networkMonitor,
            overrideJWTToken: "test-jwt-token",
            environment: .tests,
            appLifecycle: testAppLifecycle
        )

        actor StateCollector {
            var states: [String] = []
            func add(_ state: String) {
                states.append(state)
            }
            func getStates() -> [String] {
                states
            }
        }

        let collector = StateCollector()

        // Observe states in background
        let observerTask = Task {
            for await state in await stateMachine.stateSequence {
                let stateName: String
                switch state {
                case .idle:
                    stateName = "idle"
                case .registering:
                    stateName = "registering"
                case .authenticatingBackend:
                    stateName = "authenticatingBackend"
                case .ready:
                    stateName = "ready"
                case .backgrounded:
                    stateName = "backgrounded"
                case .error:
                    stateName = "error"
                case .authorizing:
                    stateName = "authorizing"
                case .deleting:
                    stateName = "deleting"
                case .stopping:
                    stateName = "stopping"
                }
                await collector.add(stateName)

                // Stop after we see the backgrounded -> ready transition
                let states = await collector.getStates()
                if states.count >= 2 {
                    let lastTwo = Array(states.suffix(2))
                    if lastTwo == ["backgrounded", "ready"] {
                        break
                    }
                }
            }
        }

        // Register
        await stateMachine.register(clientId: clientId)

        // Wait for ready state
        _ = try await waitForState(stateMachine, timeout: 30) { state in
            if case .ready = state { return true }
            if case .error = state { return true }
            return false
        }

        // Give the notification observer Task time to start listening
        try await Task.sleep(for: .milliseconds(100))

        // Simulate background
        NotificationCenter.default.post(name: testAppLifecycle.didEnterBackgroundNotification, object: nil)

        // Wait for backgrounded
        _ = try await waitForState(stateMachine, timeout: 5) { state in
            if case .backgrounded = state { return true }
            return false
        }

        // Simulate foreground
        NotificationCenter.default.post(name: testAppLifecycle.willEnterForegroundNotification, object: nil)

        // Wait for ready again
        _ = try await waitForState(stateMachine, timeout: 5) { state in
            if case .ready = state { return true }
            return false
        }

        // Wait for observer to finish
        observerTask.cancel()

        // Verify state progression includes backgrounded
        let observedStates = await collector.getStates()
        #expect(observedStates.contains("ready"))
        #expect(observedStates.contains("backgrounded"))

        // Clean up
        let finalState = await stateMachine.state
        if case .ready(_, let result) = finalState {
            try? result.client.deleteLocalDatabase()
        }
        try? await fixtures.cleanup()
    }
}
