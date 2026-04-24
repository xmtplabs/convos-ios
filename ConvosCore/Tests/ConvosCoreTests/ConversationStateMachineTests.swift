@preconcurrency @testable import ConvosCore
import ConvosInvites
import Foundation
import GRDB
import Testing
import XMTPiOS

// MARK: - Test Helpers

private let testEnvironment = AppEnvironment.tests
private let testPlatformProviders = PlatformProviders.mock

/// Comprehensive tests for ConversationStateMachine
///
/// Tests cover:
/// - Conversation creation flow (uninitialized → creating → ready)
/// - Message queuing during conversation creation
/// - State transitions and error handling
/// - Delete and stop flows
/// - State sequence observation
/// - Multiple conversation creation
@Suite("ConversationStateMachine Tests", .serialized, .timeLimit(.minutes(3)))
struct ConversationStateMachineTests {
    // MARK: - Test Helpers

    /// Waits for messages to be saved to the database by polling with a timeout
    ///
    /// This function polls the database to check if the expected number of messages
    /// have been saved. This is more efficient and deterministic than fixed sleep durations.
    ///
    /// - Parameters:
    ///   - conversationId: The conversation ID to check for messages
    ///   - expectedCount: The expected number of messages
    ///   - databaseReader: Database reader for checking messages
    ///   - timeout: Maximum time to wait (default: 10 seconds)
    /// - Throws: TestError if timeout is reached
    private func waitForMessages(
        conversationId: String,
        expectedCount: Int,
        databaseReader: any DatabaseReader,
        timeout: Duration = .seconds(10)
    ) async throws {
        let deadline = ContinuousClock.now + timeout

        while ContinuousClock.now < deadline {
            // Check if messages have been saved
            let messageCount = try await databaseReader.read { db in
                try DBMessage
                    .filter(DBMessage.Columns.conversationId == conversationId)
                    .fetchCount(db)
            }

            if messageCount >= expectedCount {
                return
            }

            // Poll every 100ms
            try await Task.sleep(for: .milliseconds(100))
        }

        throw TestError.timeout("Timed out waiting for \(expectedCount) messages to be saved")
    }

    /// Test-specific error type
    private enum TestError: Error {
        case timeout(String)
    }

    // MARK: - Creation Flow Tests

    @Test("Create flow reaches ready state")
    func testCreateFlow() async throws {
        let fixtures = TestFixtures()

        // Get a real messaging service from the cache
                let messagingService = fixtures.makeFreshMessagingService()

        let stateMachine = ConversationStateMachine(
            sessionStateManager: messagingService.sessionStateManager,
            identityStore: fixtures.identityStore,
            databaseReader: fixtures.databaseManager.dbReader,
            databaseWriter: fixtures.databaseManager.dbWriter,
            environment: testEnvironment,
            clientConversationId: DBConversation.generateDraftConversationId()
        )

        // Start in uninitialized state
        let initialState = await stateMachine.state
        #expect(initialState == .uninitialized)

        // Trigger create
        await stateMachine.create()

        // Wait for ready state
        var result: ConversationReadyResult?
        for await state in await stateMachine.stateSequence {
            switch state {
            case .ready(let readyResult):
                result = readyResult
            case .error(let error):
                Issue.record("Creation failed: \(error)")
                // Clean up and return early on error
                await messagingService.stopAndDelete()
                try? await fixtures.cleanup()
                return
            default:
                continue
            }

            if result != nil {
                break
            }
        }

        #expect(result != nil, "Should reach ready state")
        #expect(result?.origin == .created, "Origin should be created")
        #expect(result?.conversationId.isEmpty == false, "Should have conversation ID")

        // Clean up
        await messagingService.stopAndDelete()
        try? await fixtures.cleanup()
    }

    @Test("Create transitions through expected states")
    func testCreateStateTransitions() async throws {
        let fixtures = TestFixtures()

        // Get a real messaging service from the cache
                let messagingService = fixtures.makeFreshMessagingService()

        let stateMachine = ConversationStateMachine(
            sessionStateManager: messagingService.sessionStateManager,
            identityStore: fixtures.identityStore,
            databaseReader: fixtures.databaseManager.dbReader,
            databaseWriter: fixtures.databaseManager.dbWriter,
            environment: testEnvironment,
            clientConversationId: DBConversation.generateDraftConversationId()
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
                case .uninitialized:
                    stateName = "uninitialized"
                case .creating:
                    stateName = "creating"
                case .ready:
                    stateName = "ready"
                case .error:
                    stateName = "error"
                default:
                    stateName = "other"
                }
                await collector.add(stateName)

                if stateName == "ready" || stateName == "error" {
                    break
                }
            }
        }

        // Trigger create
        await stateMachine.create()

        // Wait for observer to finish
        await observerTask.value

        // Verify state progression
        let observedStates = await collector.getStates()
        #expect(observedStates.contains("creating"), "Should transition to creating")
        #expect(observedStates.contains("ready"), "Should reach ready")

        // Clean up
        await messagingService.stopAndDelete()
        try? await fixtures.cleanup()
    }

    // MARK: - Message Queuing Tests

    @Test("Messages queued during creation are sent when ready")
    func testMessageQueueingDuringCreation() async throws {
        let fixtures = TestFixtures()

        // Get a real messaging service from the cache
                let messagingService = fixtures.makeFreshMessagingService()

        let stateMachine = ConversationStateMachine(
            sessionStateManager: messagingService.sessionStateManager,
            identityStore: fixtures.identityStore,
            databaseReader: fixtures.databaseManager.dbReader,
            databaseWriter: fixtures.databaseManager.dbWriter,
            environment: testEnvironment,
            clientConversationId: DBConversation.generateDraftConversationId()
        )

        // Trigger create
        await stateMachine.create()

        // Queue messages while creating (before ready)
        await stateMachine.sendMessage(text: "Message 1")
        await stateMachine.sendMessage(text: "Message 2")

        // Wait for ready state
        var conversationId: String?
        for await state in await stateMachine.stateSequence {
            if case .ready(let result) = state {
                conversationId = result.conversationId
                break
            }
        }

        #expect(conversationId != nil, "Should have conversation ID")

        // Wait for messages to be sent and saved
        if let convId = conversationId {
            try await waitForMessages(
                conversationId: convId,
                expectedCount: 2,
                databaseReader: fixtures.databaseManager.dbReader
            )
        }

        // Verify messages were saved
        if let convId = conversationId {
            let messages = try await fixtures.databaseManager.dbReader.read { db in
                try DBMessage
                    .filter(DBMessage.Columns.conversationId == convId)
                    .fetchAll(db)
            }
            #expect(messages.count >= 2, "Queued messages should be sent")
        }

        // Clean up
        await messagingService.stopAndDelete()
        try? await fixtures.cleanup()
    }

    // MARK: - Delete Flow Tests

    // MARK: - Stop Flow Tests

    @Test("Stop transitions to uninitialized without deleting")
    func testStopFlow() async throws {
        let fixtures = TestFixtures()

        // Get a real messaging service from the cache
                let messagingService = fixtures.makeFreshMessagingService()

        let stateMachine = ConversationStateMachine(
            sessionStateManager: messagingService.sessionStateManager,
            identityStore: fixtures.identityStore,
            databaseReader: fixtures.databaseManager.dbReader,
            databaseWriter: fixtures.databaseManager.dbWriter,
            environment: testEnvironment,
            clientConversationId: DBConversation.generateDraftConversationId()
        )

        // Create conversation first
        await stateMachine.create()

        var conversationId: String?
        do {
            conversationId = try await withTimeout(seconds: 120) {
                for await state in await stateMachine.stateSequence {
                    if case .ready(let result) = state {
                        return result.conversationId
                    }
                }
                return nil
            }
        } catch {
            Issue.record("Timed out waiting for conversation creation: \(error)")
        }

        guard let convId = conversationId else {
            Issue.record("No conversation ID")
            await messagingService.stopAndDelete()
            try? await fixtures.cleanup()
            return
        }

        // Stop (should not delete)
        await stateMachine.stop()

        // Wait for uninitialized state
        var stoppedSuccessfully = false
        for await state in await stateMachine.stateSequence {
            if case .uninitialized = state {
                stoppedSuccessfully = true
                break
            }
        }

        #expect(stoppedSuccessfully, "Should return to uninitialized state")

        // Verify conversation still exists in database (stop doesn't delete)
        let conversation = try await fixtures.databaseManager.dbReader.read { db in
            try DBConversation
                .filter(DBConversation.Columns.id == convId)
                .fetchOne(db)
        }
        #expect(conversation != nil, "Stop should not delete conversation from database")

        // Clean up
        await messagingService.stopAndDelete()
        try? await fixtures.cleanup()
    }

    // MARK: - Multiple Conversation Tests

    @Test(
        "Creating multiple conversations sequentially works",
        .timeLimit(.minutes(4)),
        .enabled(if: ProcessInfo.processInfo.environment["XMTP_NODE_ADDRESS"] == nil,
                 "Skipped in CI: requires two sequential XMTP conversation creations which can exceed timeout on ephemeral backends")
    )
    func testMultipleSequentialConversations() async throws {
        let fixtures = TestFixtures()

        // Get a real messaging service from the cache
                let messagingService = fixtures.makeFreshMessagingService()

        // Wait for inbox to be ready before creating conversations
        do {
            _ = try await withTimeout(seconds: 120) {
                try await messagingService.sessionStateManager.waitForInboxReadyResult()
            }
        } catch {
            Issue.record("Timed out waiting for inbox to be ready: \(error)")
            await messagingService.stopAndDelete()
            try? await fixtures.cleanup()
            return
        }

        let stateMachine = ConversationStateMachine(
            sessionStateManager: messagingService.sessionStateManager,
            identityStore: fixtures.identityStore,
            databaseReader: fixtures.databaseManager.dbReader,
            databaseWriter: fixtures.databaseManager.dbWriter,
            environment: testEnvironment,
            clientConversationId: DBConversation.generateDraftConversationId()
        )

        // Create first conversation
        await stateMachine.create()

        var conversationId1: String?
        do {
            conversationId1 = try await withTimeout(seconds: 120) {
                for await state in await stateMachine.stateSequence {
                    if case .ready(let result) = state {
                        return result.conversationId
                    }
                }
                return nil
            }
        } catch {
            Issue.record("Timed out waiting for first conversation to be ready: \(error)")
            await messagingService.stopAndDelete()
            try? await fixtures.cleanup()
            return
        }

        #expect(conversationId1 != nil, "Should have first conversation ID")

        // Stop and create another
        await stateMachine.stop()

        // Wait for uninitialized
        do {
            _ = try await withTimeout(seconds: 10) {
                for await state in await stateMachine.stateSequence {
                    if case .uninitialized = state {
                        return true
                    }
                }
                return false
            }
        } catch {
            Issue.record("Timed out waiting for uninitialized state: \(error)")
        }

        // Create second conversation
        await stateMachine.create()

        var conversationId2: String?
        do {
            conversationId2 = try await withTimeout(seconds: 120) {
                for await state in await stateMachine.stateSequence {
                    if case .ready(let result) = state {
                        return result.conversationId
                    }
                }
                return nil
            }
        } catch {
            Issue.record("Timed out waiting for second conversation to be ready: \(error)")
        }

        #expect(conversationId2 != nil, "Should have second conversation ID")
        #expect(conversationId1 != conversationId2, "Conversations should be different")

        // Clean up
        await messagingService.stopAndDelete()
        try? await fixtures.cleanup()
    }

    // MARK: - State Sequence Tests

    @Test("State sequence emits all state changes")
    func testStateSequenceEmission() async throws {
        let fixtures = TestFixtures()

        // Get a real messaging service from the cache
                let messagingService = fixtures.makeFreshMessagingService()

        let stateMachine = ConversationStateMachine(
            sessionStateManager: messagingService.sessionStateManager,
            identityStore: fixtures.identityStore,
            databaseReader: fixtures.databaseManager.dbReader,
            databaseWriter: fixtures.databaseManager.dbWriter,
            environment: testEnvironment,
            clientConversationId: DBConversation.generateDraftConversationId()
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

        // Observe all states
        let observerTask = Task {
            for await state in await stateMachine.stateSequence {
                let stateName: String
                switch state {
                case .uninitialized:
                    stateName = "uninitialized"
                case .creating:
                    stateName = "creating"
                case .ready:
                    stateName = "ready"
                case .error:
                    stateName = "error"
                default:
                    stateName = "other"
                }
                await collector.add(stateName)

                if stateName == "ready" {
                    break
                }
            }
        }

        // Create conversation
        await stateMachine.create()

        await observerTask.value

        // Verify state progression
        let observedStates = await collector.getStates()
        #expect(observedStates.contains("creating"), "Should emit creating state")
        #expect(observedStates.contains("ready"), "Should emit ready state")

        // Clean up
        await messagingService.stopAndDelete()
        try? await fixtures.cleanup()
    }

    // MARK: - Join Flow Tests

    @Test(
        "Join conversation while inviter is online",
        .enabled(if: ProcessInfo.processInfo.environment["XMTP_NODE_ADDRESS"] == nil,
                 "Skipped in CI: multi-client join can exceed timeout on ephemeral backends")
    )
    func testJoinConversationOnline() async throws {
        // Create separate fixtures for inviter and joiner so they have different databases
        let inviterFixtures = TestFixtures()
        let joinerFixtures = TestFixtures()

        // Setup inviter messaging service and state machine
                let inviterMessagingService = inviterFixtures.makeFreshMessagingService()

        // Wait for inviter inbox to be ready before creating conversation
        do {
            _ = try await withTimeout(seconds: 120) {
                try await inviterMessagingService.sessionStateManager.waitForInboxReadyResult()
            }
        } catch {
            Issue.record("Timed out waiting for inviter inbox to be ready: \(error)")
            await inviterMessagingService.stopAndDelete()
            try? await inviterFixtures.cleanup()
            return
        }

        let inviterStateMachine = ConversationStateMachine(
            sessionStateManager: inviterMessagingService.sessionStateManager,
            identityStore: inviterFixtures.identityStore,
            databaseReader: inviterFixtures.databaseManager.dbReader,
            databaseWriter: inviterFixtures.databaseManager.dbWriter,
            environment: testEnvironment,
            clientConversationId: DBConversation.generateDraftConversationId()
        )

        // Create conversation as inviter
        await inviterStateMachine.create()

        // Wait for ready state and get conversation ID
        var inviterConversationId: String?
        do {
            inviterConversationId = try await withTimeout(seconds: 120) {
                for await state in await inviterStateMachine.stateSequence {
                    if case .ready(let result) = state {
                        return result.conversationId
                    }
                }
                throw TestError.timeout("Never reached ready state")
            }
        } catch {
            Issue.record("Timed out waiting for inviter to be ready: \(error)")
            await inviterMessagingService.stopAndDelete()
            try? await inviterFixtures.cleanup()
            return
        }

        guard let convId = inviterConversationId else {
            Issue.record("No conversation ID from inviter")
            await inviterMessagingService.stopAndDelete()
            try? await inviterFixtures.cleanup()
            return
        }

        // Fetch the invite that was automatically created
        let invite = try await inviterFixtures.databaseManager.dbReader.read { db in
            try DBInvite
                .filter(DBInvite.Columns.conversationId == convId)
                .fetchOne(db)?
                .hydrateInvite()
        }

        guard let invite else {
            Issue.record("Could not fetch invite from database")
            await inviterMessagingService.stopAndDelete()
            try? await inviterFixtures.cleanup()
            return
        }

        Log.info("Fetched invite URL: \(invite.urlSlug)")

        // Wait for inviter's sync streams to be fully ready before joiner connects
        // This prevents a race condition where the joiner sends a DM before the inviter's
        // message stream is connected to receive it
        try await waitUntil(timeout: .seconds(10)) {
            await inviterMessagingService.sessionStateManager.isSyncReady
        }

        // Setup joiner messaging service and state machine
                let joinerMessagingService = joinerFixtures.makeFreshMessagingService()

        // Wait for joiner inbox to be ready before joining
        do {
            _ = try await withTimeout(seconds: 120) {
                try await joinerMessagingService.sessionStateManager.waitForInboxReadyResult()
            }
        } catch {
            Issue.record("Timed out waiting for joiner inbox to be ready: \(error)")
            await inviterMessagingService.stopAndDelete()
            await joinerMessagingService.stopAndDelete()
            try? await inviterFixtures.cleanup()
            try? await joinerFixtures.cleanup()
            return
        }

        // Wait for joiner's sync streams to be fully ready before joining.
        // The XMTP SDK connection pool must be fully initialized to avoid
        // "Pool needs to reconnect before use" errors.
        try await waitUntil(timeout: .seconds(10)) {
            await joinerMessagingService.sessionStateManager.isSyncReady
        }

        let joinerStateMachine = ConversationStateMachine(
            sessionStateManager: joinerMessagingService.sessionStateManager,
            identityStore: joinerFixtures.identityStore,
            databaseReader: joinerFixtures.databaseManager.dbReader,
            databaseWriter: joinerFixtures.databaseManager.dbWriter,
            environment: testEnvironment,
            clientConversationId: DBConversation.generateDraftConversationId()
        )

        // Join conversation as joiner
        await joinerStateMachine.join(inviteCode: invite.urlSlug)

        // Wait for ready state
        // Use 90s timeout - join can be very slow on CI due to network latency with Fly.io
        var joinerConversationId: String?
        do {
            joinerConversationId = try await withTimeout(seconds: 150) {
                for await state in await joinerStateMachine.stateSequence {
                    switch state {
                    case .ready(let result):
                        return result.conversationId
                    case .error(let error):
                        Issue.record("Join failed: \(error)")
                        throw error
                    default:
                        continue
                    }
                }
                throw TestError.timeout("Never reached ready state")
            }
        } catch {
            Issue.record("Timed out waiting for joiner to reach ready state: \(error)")
        }

        #expect(joinerConversationId != nil, "Should have joined conversation")

        // Clean up
        await inviterMessagingService.stopAndDelete()
        await joinerMessagingService.stopAndDelete()
        try? await inviterFixtures.cleanup()
        try? await joinerFixtures.cleanup()
    }

    // MARK: - Cancellation Tests

    @Test("Stop during pending operations doesn't hang")
    func testStopDuringOperationsDoesntHang() async throws {
        let fixtures = TestFixtures()

                let messagingService = fixtures.makeFreshMessagingService()

        let stateMachine = ConversationStateMachine(
            sessionStateManager: messagingService.sessionStateManager,
            identityStore: fixtures.identityStore,
            databaseReader: fixtures.databaseManager.dbReader,
            databaseWriter: fixtures.databaseManager.dbWriter,
            environment: testEnvironment,
            clientConversationId: DBConversation.generateDraftConversationId()
        )

        // Queue multiple actions rapidly
        await stateMachine.create()
        await stateMachine.sendMessage(text: "Message 1")
        await stateMachine.sendMessage(text: "Message 2")

        // Stop immediately - this tests that stop can cancel pending operations
        await stateMachine.stop()

        // Verify stop completes within a reasonable time (not hung)
        var stoppedSuccessfully = false
        do {
            stoppedSuccessfully = try await withTimeout(seconds: 5) {
                for await state in await stateMachine.stateSequence {
                    if case .uninitialized = state {
                        return true
                    }
                }
                return false
            }
        } catch {
            Issue.record("Stop operation hung or timed out: \(error)")
        }

        #expect(stoppedSuccessfully, "Stop should complete without hanging")

        // Verify state machine can be reused after stop
        await stateMachine.create()

        var canCreateAfterStop = false
        do {
            canCreateAfterStop = try await withTimeout(seconds: 10) {
                for await state in await stateMachine.stateSequence {
                    if case .ready = state {
                        return true
                    }
                }
                return false
            }
        } catch {
            Issue.record("Failed to create conversation after stop: \(error)")
        }

        #expect(canCreateAfterStop, "State machine should work after stop")

        // Clean up
        await messagingService.stopAndDelete()
        try? await fixtures.cleanup()
    }

    @Test("Stop cancels queued message processing")
    func testStopCancelsQueuedMessages() async throws {
        let fixtures = TestFixtures()

        // Get a real messaging service from the cache
                let messagingService = fixtures.makeFreshMessagingService()

        let stateMachine = ConversationStateMachine(
            sessionStateManager: messagingService.sessionStateManager,
            identityStore: fixtures.identityStore,
            databaseReader: fixtures.databaseManager.dbReader,
            databaseWriter: fixtures.databaseManager.dbWriter,
            environment: testEnvironment,
            clientConversationId: DBConversation.generateDraftConversationId()
        )

        // Queue messages before creating (will be queued)
        await stateMachine.sendMessage(text: "Queued message 1")
        await stateMachine.sendMessage(text: "Queued message 2")

        // Start create
        await stateMachine.create()

        // Immediately stop (before messages can be sent)
        await stateMachine.stop()

        // Verify it transitions to uninitialized
        var stoppedSuccessfully = false
        do {
            stoppedSuccessfully = try await withTimeout(seconds: 5) {
                for await state in await stateMachine.stateSequence {
                    if case .uninitialized = state {
                        return true
                    }
                }
                return false
            }
        } catch {
            Issue.record("Timed out waiting for stop: \(error)")
        }

        #expect(stoppedSuccessfully, "Should successfully stop and cancel message queue")

        // Clean up
        await messagingService.stopAndDelete()
        try? await fixtures.cleanup()
    }

    // MARK: - UseExisting Flow Tests

    @Test("UseExisting transitions to ready state with existing origin")
    func testUseExistingFlow() async throws {
        let fixtures = TestFixtures()

        // Get a real messaging service from the cache
                let messagingService = fixtures.makeFreshMessagingService()

        // First create a conversation so we have a valid conversationId
        let createStateMachine = ConversationStateMachine(
            sessionStateManager: messagingService.sessionStateManager,
            identityStore: fixtures.identityStore,
            databaseReader: fixtures.databaseManager.dbReader,
            databaseWriter: fixtures.databaseManager.dbWriter,
            environment: testEnvironment,
            clientConversationId: DBConversation.generateDraftConversationId()
        )

        await createStateMachine.create()

        var createdConversationId: String?
        do {
            createdConversationId = try await withTimeout(seconds: 120) {
                for await state in await createStateMachine.stateSequence {
                    if case .ready(let result) = state {
                        return result.conversationId
                    }
                }
                return nil
            }
        } catch {
            Issue.record("Timed out waiting for conversation creation: \(error)")
        }

        guard let conversationId = createdConversationId else {
            Issue.record("Failed to create conversation")
            await messagingService.stopAndDelete()
            try? await fixtures.cleanup()
            return
        }

        // Now test useExisting with a fresh state machine
        let stateMachine = ConversationStateMachine(
            sessionStateManager: messagingService.sessionStateManager,
            identityStore: fixtures.identityStore,
            databaseReader: fixtures.databaseManager.dbReader,
            databaseWriter: fixtures.databaseManager.dbWriter,
            environment: testEnvironment,
            clientConversationId: DBConversation.generateDraftConversationId()
        )

        // Start in uninitialized state
        let initialState = await stateMachine.state
        #expect(initialState == .uninitialized)

        // Trigger useExisting
        await stateMachine.useExisting(conversationId: conversationId)

        // Wait for ready state
        var result: ConversationReadyResult?
        do {
            result = try await withTimeout(seconds: 120) {
                for await state in await stateMachine.stateSequence {
                    switch state {
                    case .ready(let readyResult):
                        return readyResult
                    case .error(let error):
                        throw error
                    default:
                        continue
                    }
                }
                return nil
            }
        } catch {
            Issue.record("UseExisting timed out or failed: \(error)")
            await messagingService.stopAndDelete()
            try? await fixtures.cleanup()
            return
        }

        #expect(result != nil, "Should reach ready state")
        #expect(result?.origin == .existing, "Origin should be existing")
        #expect(result?.conversationId == conversationId, "Should have correct conversation ID")

        // Clean up
        await messagingService.stopAndDelete()
        try? await fixtures.cleanup()
    }

    @Test("UseExisting allows sending messages immediately")
    func testUseExistingWithMessages() async throws {
        let fixtures = TestFixtures()

        // Get a real messaging service from the cache
                let messagingService = fixtures.makeFreshMessagingService()

        // First create a conversation so we have a valid conversationId
        let createStateMachine = ConversationStateMachine(
            sessionStateManager: messagingService.sessionStateManager,
            identityStore: fixtures.identityStore,
            databaseReader: fixtures.databaseManager.dbReader,
            databaseWriter: fixtures.databaseManager.dbWriter,
            environment: testEnvironment,
            clientConversationId: DBConversation.generateDraftConversationId()
        )

        await createStateMachine.create()

        var createdConversationId: String?
        do {
            createdConversationId = try await withTimeout(seconds: 120) {
                for await state in await createStateMachine.stateSequence {
                    if case .ready(let result) = state {
                        return result.conversationId
                    }
                }
                return nil
            }
        } catch {
            Issue.record("Timed out waiting for conversation creation: \(error)")
        }

        guard let conversationId = createdConversationId else {
            Issue.record("Failed to create conversation")
            await messagingService.stopAndDelete()
            try? await fixtures.cleanup()
            return
        }

        // Now test useExisting and sending messages with a fresh state machine
        let stateMachine = ConversationStateMachine(
            sessionStateManager: messagingService.sessionStateManager,
            identityStore: fixtures.identityStore,
            databaseReader: fixtures.databaseManager.dbReader,
            databaseWriter: fixtures.databaseManager.dbWriter,
            environment: testEnvironment,
            clientConversationId: DBConversation.generateDraftConversationId()
        )

        // Trigger useExisting
        await stateMachine.useExisting(conversationId: conversationId)

        // Wait for ready state
        do {
            _ = try await withTimeout(seconds: 120) {
                for await state in await stateMachine.stateSequence {
                    if case .ready = state {
                        return true
                    }
                }
                return false
            }
        } catch {
            Issue.record("UseExisting timed out: \(error)")
            await messagingService.stopAndDelete()
            try? await fixtures.cleanup()
            return
        }

        // Send messages after useExisting
        await stateMachine.sendMessage(text: "Message via useExisting 1")
        await stateMachine.sendMessage(text: "Message via useExisting 2")

        // Wait for messages to be saved
        try await waitForMessages(
            conversationId: conversationId,
            expectedCount: 2,
            databaseReader: fixtures.databaseManager.dbReader
        )

        // Verify messages were saved
        let messages = try await fixtures.databaseManager.dbReader.read { db in
            try DBMessage
                .filter(DBMessage.Columns.conversationId == conversationId)
                .fetchAll(db)
        }
        #expect(messages.count >= 2, "Messages should be sent via useExisting")

        // Clean up
        await messagingService.stopAndDelete()
        try? await fixtures.cleanup()
    }

    @Test("UseExisting emits correct state sequence")
    func testUseExistingStateSequence() async throws {
        let fixtures = TestFixtures()

        // Get a real messaging service from the cache
                let messagingService = fixtures.makeFreshMessagingService()

        // First create a conversation
        let createStateMachine = ConversationStateMachine(
            sessionStateManager: messagingService.sessionStateManager,
            identityStore: fixtures.identityStore,
            databaseReader: fixtures.databaseManager.dbReader,
            databaseWriter: fixtures.databaseManager.dbWriter,
            environment: testEnvironment,
            clientConversationId: DBConversation.generateDraftConversationId()
        )

        await createStateMachine.create()

        var createdConversationId: String?
        do {
            createdConversationId = try await withTimeout(seconds: 120) {
                for await state in await createStateMachine.stateSequence {
                    if case .ready(let result) = state {
                        return result.conversationId
                    }
                }
                return nil
            }
        } catch {
            Issue.record("Timed out waiting for conversation creation: \(error)")
        }

        guard let conversationId = createdConversationId else {
            Issue.record("Failed to create conversation")
            await messagingService.stopAndDelete()
            try? await fixtures.cleanup()
            return
        }

        // Test useExisting state sequence
        let stateMachine = ConversationStateMachine(
            sessionStateManager: messagingService.sessionStateManager,
            identityStore: fixtures.identityStore,
            databaseReader: fixtures.databaseManager.dbReader,
            databaseWriter: fixtures.databaseManager.dbWriter,
            environment: testEnvironment,
            clientConversationId: DBConversation.generateDraftConversationId()
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
                case .uninitialized:
                    stateName = "uninitialized"
                case .ready(let result) where result.origin == .existing:
                    stateName = "ready_existing"
                case .ready:
                    stateName = "ready"
                case .error:
                    stateName = "error"
                default:
                    stateName = "other"
                }
                await collector.add(stateName)

                if stateName == "ready_existing" || stateName == "error" {
                    break
                }
            }
        }

        // Trigger useExisting
        await stateMachine.useExisting(conversationId: conversationId)

        // Wait for observer to finish
        await observerTask.value

        // Verify state progression - useExisting should go directly to ready
        let observedStates = await collector.getStates()
        #expect(observedStates.contains("ready_existing"), "Should reach ready with existing origin")
        // Verify no intermediate states (unlike create which goes through creating)
        #expect(!observedStates.contains("other"), "Should not have intermediate states")

        // Clean up
        await messagingService.stopAndDelete()
        try? await fixtures.cleanup()
    }

    @Test("UseExisting can be called after stop")
    func testUseExistingAfterStop() async throws {
        let fixtures = TestFixtures()

        // Get a real messaging service from the cache
                let messagingService = fixtures.makeFreshMessagingService()

        let stateMachine = ConversationStateMachine(
            sessionStateManager: messagingService.sessionStateManager,
            identityStore: fixtures.identityStore,
            databaseReader: fixtures.databaseManager.dbReader,
            databaseWriter: fixtures.databaseManager.dbWriter,
            environment: testEnvironment,
            clientConversationId: DBConversation.generateDraftConversationId()
        )

        // Create conversation first
        await stateMachine.create()

        var conversationId: String?
        do {
            conversationId = try await withTimeout(seconds: 120) {
                for await state in await stateMachine.stateSequence {
                    if case .ready(let result) = state {
                        return result.conversationId
                    }
                }
                return nil
            }
        } catch {
            Issue.record("Timed out waiting for conversation creation: \(error)")
        }

        guard let convId = conversationId else {
            Issue.record("No conversation ID")
            await messagingService.stopAndDelete()
            try? await fixtures.cleanup()
            return
        }

        // Stop the state machine
        await stateMachine.stop()

        // Wait for uninitialized state
        do {
            _ = try await withTimeout(seconds: 10) {
                for await state in await stateMachine.stateSequence {
                    if case .uninitialized = state {
                        return true
                    }
                }
                return false
            }
        } catch {
            Issue.record("Timed out waiting for uninitialized: \(error)")
        }

        // Now use useExisting with the same conversation
        await stateMachine.useExisting(conversationId: convId)

        // Wait for ready state
        var result: ConversationReadyResult?
        do {
            result = try await withTimeout(seconds: 5) {
                for await state in await stateMachine.stateSequence {
                    if case .ready(let readyResult) = state {
                        return readyResult
                    }
                }
                throw TestError.timeout("Never reached ready state")
            }
        } catch {
            Issue.record("UseExisting after stop failed: \(error)")
        }

        #expect(result != nil, "Should reach ready state after stop + useExisting")
        #expect(result?.origin == .existing, "Origin should be existing")
        #expect(result?.conversationId == convId, "Should have same conversation ID")

        // Clean up
        await messagingService.stopAndDelete()
        try? await fixtures.cleanup()
    }

    // MARK: - Empty Tag Rejection Tests

    @Test("Join with empty-tag invite transitions to error state")
    func testJoinWithEmptyTagInviteShowsError() async throws {
        let fixtures = TestFixtures()

                let messagingService = fixtures.makeFreshMessagingService()

        let stateMachine = ConversationStateMachine(
            sessionStateManager: messagingService.sessionStateManager,
            identityStore: fixtures.identityStore,
            databaseReader: fixtures.databaseManager.dbReader,
            databaseWriter: fixtures.databaseManager.dbWriter,
            environment: testEnvironment,
            clientConversationId: DBConversation.generateDraftConversationId()
        )

        let privateKey: Data = Data(repeating: 0x42, count: 32)

        var payload = InvitePayload()
        payload.tag = ""
        payload.conversationToken = Data(repeating: 0x01, count: 32)
        payload.creatorInboxID = Data(repeating: 0xAB, count: 32)
        let signature = try payload.sign(with: privateKey)

        var emptyTagInvite = SignedInvite()
        try emptyTagInvite.setPayload(payload)
        emptyTagInvite.signature = signature

        let slug = try emptyTagInvite.toURLSafeSlug()

        await stateMachine.join(inviteCode: slug)

        let errorResult: ConversationStateMachineError? = try await withTimeout(seconds: 10) {
            for await state in await stateMachine.stateSequence {
                if case .error(let error) = state {
                    return error as? ConversationStateMachineError
                }
                if case .ready = state {
                    Issue.record("should not reach ready state with an empty-tag invite")
                    return nil
                }
            }
            return nil
        }

        #expect(errorResult != nil, "should transition to error state for empty-tag invite")
        #expect(
            errorResult?.description.contains("not valid") == true,
            "error should indicate an invalid code (got: \(errorResult?.description ?? "nil"))"
        )

        let conversations = try await fixtures.databaseManager.dbReader.read { db in
            try DBConversation.fetchAll(db)
        }
        let nonDraftConversations = conversations.filter { !$0.id.hasPrefix("draft-") && !$0.isUnused }
        #expect(nonDraftConversations.isEmpty, "no conversation should be matched or created for an empty-tag invite")

        await messagingService.stopAndDelete()
        try? await fixtures.cleanup()
    }
}

// MARK: - StateSequence Contract Tests

private actor StateCollector {
    var values: [String] = []
    func append(_ value: String) { values.append(value) }
}

private actor StateCounter {
    var value: Int = 0
    func increment() { value += 1 }
}

@Suite("ConversationStateManager stateSequence", .serialized)
struct ConversationStateManagerStateSequenceTests {
    @Test("stateSequence delivers current state immediately on subscribe")
    func testCurrentStateOnSubscribe() async throws {
        let mock = MockConversationStateManager()
        let readyResult = ConversationReadyResult(conversationId: "test-123", origin: .created)
        mock.setState(.ready(readyResult))

        var receivedState: ConversationStateMachine.State?
        for await state in mock.stateSequence {
            receivedState = state
            break
        }

        guard case .ready(let result) = receivedState else {
            Issue.record("Expected .ready state, got \(String(describing: receivedState))")
            return
        }
        #expect(result.conversationId == "test-123")
    }

    @Test("Multiple observers receive the same state updates")
    func testMultipleObservers() async throws {
        let mock = MockConversationStateManager()
        let collector1 = StateCollector()
        let collector2 = StateCollector()

        async let result1: Void = {
            for await state in mock.stateSequence {
                await collector1.append("\(state)")
                if case .ready = state { break }
            }
        }()

        async let result2: Void = {
            for await state in mock.stateSequence {
                await collector2.append("\(state)")
                if case .ready = state { break }
            }
        }()

        try await Task.sleep(for: .milliseconds(50))
        mock.setState(.creating)
        try await Task.sleep(for: .milliseconds(50))
        mock.setState(.ready(ConversationReadyResult(conversationId: "abc", origin: .created)))

        await result1
        await result2

        let states1 = await collector1.values
        let states2 = await collector2.values

        #expect(states1.count >= 2, "Observer 1 should have received at least initial + ready states")
        #expect(states2.count >= 2, "Observer 2 should have received at least initial + ready states")

        let ready1 = states1.contains { $0.contains("ready") }
        let ready2 = states2.contains { $0.contains("ready") }
        #expect(ready1, "Observer 1 should have received ready state")
        #expect(ready2, "Observer 2 should have received ready state")
    }

    @Test("Canceling observation stops receiving updates")
    func testCancelStopsUpdates() async throws {
        let mock = MockConversationStateManager()
        let counter = StateCounter()

        let task = Task {
            for await _ in mock.stateSequence {
                await counter.increment()
                if await counter.value >= 2 { break }
            }
        }

        try await Task.sleep(for: .milliseconds(50))
        mock.setState(.creating)
        await task.value

        let countAfterCancel = await counter.value
        mock.setState(.ready(ConversationReadyResult(conversationId: "abc", origin: .created)))
        try await Task.sleep(for: .milliseconds(50))

        #expect(await counter.value == countAfterCancel)
    }
}
