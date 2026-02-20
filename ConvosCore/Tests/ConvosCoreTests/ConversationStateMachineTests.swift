@preconcurrency @testable import ConvosCore
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
@Suite("ConversationStateMachine Tests", .serialized, .timeLimit(.minutes(5)))
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
        let unusedInboxCache = UnusedConversationCache(
            keychainService: fixtures.keychainService,
            identityStore: fixtures.identityStore,
            platformProviders: testPlatformProviders
        )
        let (messagingService, _) = await unusedInboxCache.consumeOrCreateMessagingService(
            databaseWriter: fixtures.databaseManager.dbWriter,
            databaseReader: fixtures.databaseManager.dbReader,
            environment: testEnvironment
        )

        let stateMachine = ConversationStateMachine(
            inboxStateManager: messagingService.inboxStateManager,
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
        let unusedInboxCache = UnusedConversationCache(
            keychainService: fixtures.keychainService,
            identityStore: fixtures.identityStore,
            platformProviders: testPlatformProviders
        )
        let (messagingService, _) = await unusedInboxCache.consumeOrCreateMessagingService(
            databaseWriter: fixtures.databaseManager.dbWriter,
            databaseReader: fixtures.databaseManager.dbReader,
            environment: testEnvironment
        )

        let stateMachine = ConversationStateMachine(
            inboxStateManager: messagingService.inboxStateManager,
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
        let unusedInboxCache = UnusedConversationCache(
            keychainService: fixtures.keychainService,
            identityStore: fixtures.identityStore,
            platformProviders: testPlatformProviders
        )
        let (messagingService, _) = await unusedInboxCache.consumeOrCreateMessagingService(
            databaseWriter: fixtures.databaseManager.dbWriter,
            databaseReader: fixtures.databaseManager.dbReader,
            environment: testEnvironment
        )

        let stateMachine = ConversationStateMachine(
            inboxStateManager: messagingService.inboxStateManager,
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

    @Test("Delete flow cleans up conversation")
    func testDeleteFlow() async throws {
        let fixtures = TestFixtures()

        // Get a real messaging service from the cache
        let unusedInboxCache = UnusedConversationCache(
            keychainService: fixtures.keychainService,
            identityStore: fixtures.identityStore,
            platformProviders: testPlatformProviders
        )
        let (messagingService, _) = await unusedInboxCache.consumeOrCreateMessagingService(
            databaseWriter: fixtures.databaseManager.dbWriter,
            databaseReader: fixtures.databaseManager.dbReader,
            environment: testEnvironment
        )

        let stateMachine = ConversationStateMachine(
            inboxStateManager: messagingService.inboxStateManager,
            identityStore: fixtures.identityStore,
            databaseReader: fixtures.databaseManager.dbReader,
            databaseWriter: fixtures.databaseManager.dbWriter,
            environment: testEnvironment,
            clientConversationId: DBConversation.generateDraftConversationId()
        )

        // Create conversation first
        await stateMachine.create()

        var conversationId: String?
        for await state in await stateMachine.stateSequence {
            if case .ready(let result) = state {
                conversationId = result.conversationId
                break
            }
        }

        guard let convId = conversationId else {
            Issue.record("No conversation ID")
            await messagingService.stopAndDelete()
            try? await fixtures.cleanup()
            return
        }

        // Verify conversation exists in database
        let conversationBefore = try await fixtures.databaseManager.dbReader.read { db in
            try DBConversation
                .filter(DBConversation.Columns.id == convId)
                .fetchOne(db)
        }
        #expect(conversationBefore != nil, "Conversation should exist before delete")

        // Delete conversation
        await stateMachine.delete()

        // Wait for uninitialized state
        var deletedSuccessfully = false
        for await state in await stateMachine.stateSequence {
            if case .uninitialized = state {
                deletedSuccessfully = true
                break
            }
        }

        #expect(deletedSuccessfully, "Should return to uninitialized state")

        // Verify conversation was removed from database
        let conversationAfter = try await fixtures.databaseManager.dbReader.read { db in
            try DBConversation
                .filter(DBConversation.Columns.id == convId)
                .fetchOne(db)
        }
        #expect(conversationAfter == nil, "Conversation should be deleted from database")

        // Clean up (messaging service already deleted by state machine)
        try? await fixtures.cleanup()
    }

    // MARK: - Stop Flow Tests

    @Test("Stop transitions to uninitialized without deleting")
    func testStopFlow() async throws {
        let fixtures = TestFixtures()

        // Get a real messaging service from the cache
        let unusedInboxCache = UnusedConversationCache(
            keychainService: fixtures.keychainService,
            identityStore: fixtures.identityStore,
            platformProviders: testPlatformProviders
        )
        let (messagingService, _) = await unusedInboxCache.consumeOrCreateMessagingService(
            databaseWriter: fixtures.databaseManager.dbWriter,
            databaseReader: fixtures.databaseManager.dbReader,
            environment: testEnvironment
        )

        let stateMachine = ConversationStateMachine(
            inboxStateManager: messagingService.inboxStateManager,
            identityStore: fixtures.identityStore,
            databaseReader: fixtures.databaseManager.dbReader,
            databaseWriter: fixtures.databaseManager.dbWriter,
            environment: testEnvironment,
            clientConversationId: DBConversation.generateDraftConversationId()
        )

        // Create conversation first
        await stateMachine.create()

        var conversationId: String?
        for await state in await stateMachine.stateSequence {
            if case .ready(let result) = state {
                conversationId = result.conversationId
                break
            }
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

    @Test("Creating multiple conversations sequentially works", .timeLimit(.minutes(4)))
    func testMultipleSequentialConversations() async throws {
        let fixtures = TestFixtures()

        // Get a real messaging service from the cache
        let unusedInboxCache = UnusedConversationCache(
            keychainService: fixtures.keychainService,
            identityStore: fixtures.identityStore,
            platformProviders: testPlatformProviders
        )
        let (messagingService, _) = await unusedInboxCache.consumeOrCreateMessagingService(
            databaseWriter: fixtures.databaseManager.dbWriter,
            databaseReader: fixtures.databaseManager.dbReader,
            environment: testEnvironment
        )

        // Wait for inbox to be ready before creating conversations
        do {
            _ = try await withTimeout(seconds: 60) {
                try await messagingService.inboxStateManager.waitForInboxReadyResult()
            }
        } catch {
            Issue.record("Timed out waiting for inbox to be ready: \(error)")
            await messagingService.stopAndDelete()
            try? await fixtures.cleanup()
            return
        }

        let stateMachine = ConversationStateMachine(
            inboxStateManager: messagingService.inboxStateManager,
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
            conversationId1 = try await withTimeout(seconds: 60) {
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
        let unusedInboxCache = UnusedConversationCache(
            keychainService: fixtures.keychainService,
            identityStore: fixtures.identityStore,
            platformProviders: testPlatformProviders
        )
        let (messagingService, _) = await unusedInboxCache.consumeOrCreateMessagingService(
            databaseWriter: fixtures.databaseManager.dbWriter,
            databaseReader: fixtures.databaseManager.dbReader,
            environment: testEnvironment
        )

        let stateMachine = ConversationStateMachine(
            inboxStateManager: messagingService.inboxStateManager,
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
                case .deleting:
                    stateName = "deleting"
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

    @Test("Join conversation while inviter is online")
    func testJoinConversationOnline() async throws {
        // Create separate fixtures for inviter and joiner so they have different databases
        let inviterFixtures = TestFixtures()
        let joinerFixtures = TestFixtures()

        // Setup inviter messaging service and state machine
        let inviterUnusedConversationCache = UnusedConversationCache(
            keychainService: inviterFixtures.keychainService,
            identityStore: inviterFixtures.identityStore,
            platformProviders: testPlatformProviders
        )
        let (inviterMessagingService, _) = await inviterUnusedConversationCache.consumeOrCreateMessagingService(
            databaseWriter: inviterFixtures.databaseManager.dbWriter,
            databaseReader: inviterFixtures.databaseManager.dbReader,
            environment: testEnvironment
        )

        // Wait for inviter inbox to be ready before creating conversation
        do {
            _ = try await withTimeout(seconds: 60) {
                try await inviterMessagingService.inboxStateManager.waitForInboxReadyResult()
            }
        } catch {
            Issue.record("Timed out waiting for inviter inbox to be ready: \(error)")
            await inviterMessagingService.stopAndDelete()
            try? await inviterFixtures.cleanup()
            return
        }

        let inviterStateMachine = ConversationStateMachine(
            inboxStateManager: inviterMessagingService.inboxStateManager,
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
            inviterConversationId = try await withTimeout(seconds: 60) {
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
            await inviterMessagingService.inboxStateManager.isSyncReady
        }

        // Setup joiner messaging service and state machine
        let joinerUnusedConversationCache = UnusedConversationCache(
            keychainService: joinerFixtures.keychainService,
            identityStore: joinerFixtures.identityStore,
            platformProviders: testPlatformProviders
        )
        let (joinerMessagingService, _) = await joinerUnusedConversationCache.consumeOrCreateMessagingService(
            databaseWriter: joinerFixtures.databaseManager.dbWriter,
            databaseReader: joinerFixtures.databaseManager.dbReader,
            environment: testEnvironment
        )

        // Wait for joiner inbox to be ready before joining
        do {
            _ = try await withTimeout(seconds: 60) {
                try await joinerMessagingService.inboxStateManager.waitForInboxReadyResult()
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
            await joinerMessagingService.inboxStateManager.isSyncReady
        }

        let joinerStateMachine = ConversationStateMachine(
            inboxStateManager: joinerMessagingService.inboxStateManager,
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
            joinerConversationId = try await withTimeout(seconds: 90) {
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

    @Test("Join conversation while inviter is offline")
    func testJoinConversationOffline() async throws {
        // Create separate fixtures for inviter and joiner so they have different databases
        let inviterFixtures = TestFixtures()
        let joinerFixtures = TestFixtures()

        // Setup inviter messaging service and state machine
        let inviterUnusedConversationCache = UnusedConversationCache(
            keychainService: inviterFixtures.keychainService,
            identityStore: inviterFixtures.identityStore,
            platformProviders: testPlatformProviders
        )
        let (inviterMessagingService, _) = await inviterUnusedConversationCache.consumeOrCreateMessagingService(
            databaseWriter: inviterFixtures.databaseManager.dbWriter,
            databaseReader: inviterFixtures.databaseManager.dbReader,
            environment: testEnvironment
        )

        // Wait for inbox to be fully ready before creating conversation.
        // In CI, XMTP registration and authentication can take a long time,
        // so we use a generous timeout (60s) for this step.
        do {
            _ = try await withTimeout(seconds: 60) {
                try await inviterMessagingService.inboxStateManager.waitForInboxReadyResult()
            }
        } catch {
            Issue.record("Timed out waiting for inviter inbox to be ready: \(error)")
            await inviterMessagingService.stopAndDelete()
            try? await inviterFixtures.cleanup()
            return
        }

        let inviterStateMachine = ConversationStateMachine(
            inboxStateManager: inviterMessagingService.inboxStateManager,
            identityStore: inviterFixtures.identityStore,
            databaseReader: inviterFixtures.databaseManager.dbReader,
            databaseWriter: inviterFixtures.databaseManager.dbWriter,
            environment: testEnvironment,
            clientConversationId: DBConversation.generateDraftConversationId()
        )

        // Create conversation as inviter
        await inviterStateMachine.create()

        // Wait for conversation creation to complete.
        // XMTP publish() can be slow in CI, so use generous timeout.
        var inviterConversationId: String?
        var inviterInboxId: String?
        do {
            inviterConversationId = try await withTimeout(seconds: 90) {
                for await state in await inviterStateMachine.stateSequence {
                    if case .ready(let result) = state {
                        return result.conversationId
                    }
                }
                throw TestError.timeout("Never reached ready state")
            }
        } catch {
            Issue.record("Timed out waiting for conversation creation: \(error)")
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

        // Get the inbox ID and fetch the automatically created invite
        let (invite, inboxId) = try await inviterFixtures.databaseManager.dbReader.read { db in
            let conversation = try DBConversation.fetchOne(db, key: convId)
            let invite = try DBInvite
                .filter(DBInvite.Columns.conversationId == convId)
                .fetchOne(db)?
                .hydrateInvite()
            return (invite, conversation?.inboxId)
        }

        guard let invite, let inboxId else {
            Issue.record("Could not fetch invite or conversation from database")
            await inviterMessagingService.stopAndDelete()
            try? await inviterFixtures.cleanup()
            return
        }

        inviterInboxId = inboxId

        Log.info("Fetched invite URL: \(invite.urlSlug)")

        // Stop inviter's messaging service (simulating offline)
        await inviterMessagingService.stop()
        Log.info("Inviter went offline")

        // Setup joiner messaging service and state machine
        let joinerUnusedConversationCache = UnusedConversationCache(
            keychainService: joinerFixtures.keychainService,
            identityStore: joinerFixtures.identityStore,
            platformProviders: testPlatformProviders
        )
        let (joinerMessagingService, _) = await joinerUnusedConversationCache.consumeOrCreateMessagingService(
            databaseWriter: joinerFixtures.databaseManager.dbWriter,
            databaseReader: joinerFixtures.databaseManager.dbReader,
            environment: testEnvironment
        )

        let joinerStateMachine = ConversationStateMachine(
            inboxStateManager: joinerMessagingService.inboxStateManager,
            identityStore: joinerFixtures.identityStore,
            databaseReader: joinerFixtures.databaseManager.dbReader,
            databaseWriter: joinerFixtures.databaseManager.dbWriter,
            environment: testEnvironment,
            clientConversationId: DBConversation.generateDraftConversationId()
        )

        // Join conversation as joiner (should wait for inviter to come back online)
        await joinerStateMachine.join(inviteCode: invite.urlSlug)

        // Wait a moment for join request to be sent
        try await Task.sleep(for: .seconds(2))

        // Restart inviter's messaging service with the same inbox ID
        guard let inviterInbox = inviterInboxId else {
            Issue.record("No inviter inbox ID")
            await joinerMessagingService.stopAndDelete()
            try? await inviterFixtures.cleanup()
            try? await joinerFixtures.cleanup()
            return
        }

        let identity = try await inviterFixtures.identityStore.identity(for: inviterInbox)
        let restartedInviterService = MessagingService.authorizedMessagingService(
            for: inviterInbox,
            clientId: identity.clientId,
            databaseWriter: inviterFixtures.databaseManager.dbWriter,
            databaseReader: inviterFixtures.databaseManager.dbReader,
            environment: testEnvironment,
            identityStore: inviterFixtures.identityStore,
            startsStreamingServices: true,
            platformProviders: testPlatformProviders
        )

        Log.info("Inviter came back online")

        // Wait for joiner to reach ready state (join should be processed automatically)
        // Use generous timeout for CI where XMTP operations can be slow.
        var joinerConversationId: String?
        var joinerReachedReady = false

        do {
            joinerConversationId = try await withTimeout(seconds: 90) {
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
            joinerReachedReady = true
        } catch {
            Issue.record("Timed out waiting for join to complete: \(error)")
            await restartedInviterService.stopAndDelete()
            await joinerMessagingService.stopAndDelete()
            try? await inviterFixtures.cleanup()
            try? await joinerFixtures.cleanup()
            return
        }

        #expect(joinerConversationId != nil, "Should have joined conversation")
        #expect(joinerReachedReady, "Joiner should reach ready state after inviter comes online")

        // Clean up
        await restartedInviterService.stopAndDelete()
        await joinerMessagingService.stopAndDelete()
        try? await inviterFixtures.cleanup()
        try? await joinerFixtures.cleanup()
    }

    // MARK: - Cancellation Tests

    @Test("Stop during pending operations doesn't hang")
    func testStopDuringOperationsDoesntHang() async throws {
        let fixtures = TestFixtures()

        let unusedInboxCache = UnusedConversationCache(
            keychainService: fixtures.keychainService,
            identityStore: fixtures.identityStore,
            platformProviders: testPlatformProviders
        )
        let (messagingService, _) = await unusedInboxCache.consumeOrCreateMessagingService(
            databaseWriter: fixtures.databaseManager.dbWriter,
            databaseReader: fixtures.databaseManager.dbReader,
            environment: testEnvironment
        )

        let stateMachine = ConversationStateMachine(
            inboxStateManager: messagingService.inboxStateManager,
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

    @Test("Delete during message processing cancels gracefully")
    func testDeleteDuringMessageProcessing() async throws {
        let fixtures = TestFixtures()

        // Get a real messaging service from the cache
        let unusedInboxCache = UnusedConversationCache(
            keychainService: fixtures.keychainService,
            identityStore: fixtures.identityStore,
            platformProviders: testPlatformProviders
        )
        let (messagingService, _) = await unusedInboxCache.consumeOrCreateMessagingService(
            databaseWriter: fixtures.databaseManager.dbWriter,
            databaseReader: fixtures.databaseManager.dbReader,
            environment: testEnvironment
        )

        let stateMachine = ConversationStateMachine(
            inboxStateManager: messagingService.inboxStateManager,
            identityStore: fixtures.identityStore,
            databaseReader: fixtures.databaseManager.dbReader,
            databaseWriter: fixtures.databaseManager.dbWriter,
            environment: testEnvironment,
            clientConversationId: DBConversation.generateDraftConversationId()
        )

        // Create conversation
        await stateMachine.create()

        // Queue multiple messages
        await stateMachine.sendMessage(text: "Message 1")
        await stateMachine.sendMessage(text: "Message 2")
        await stateMachine.sendMessage(text: "Message 3")

        // Wait for ready state
        var conversationId: String?
        for await state in await stateMachine.stateSequence {
            if case .ready(let result) = state {
                conversationId = result.conversationId
                break
            }
        }

        #expect(conversationId != nil, "Should have conversation ID")

        // Immediately delete (while messages might still be processing)
        await stateMachine.delete()

        // Verify it transitions to uninitialized (not stuck)
        var deletedSuccessfully = false
        do {
            deletedSuccessfully = try await withTimeout(seconds: 5) {
                for await state in await stateMachine.stateSequence {
                    if case .uninitialized = state {
                        return true
                    }
                }
                return false
            }
        } catch {
            Issue.record("Timed out waiting for delete to complete: \(error)")
        }

        #expect(deletedSuccessfully, "Should successfully delete even during message processing")

        // Clean up (messaging service already deleted by state machine)
        try? await fixtures.cleanup()
    }

    @Test("Stop cancels queued message processing")
    func testStopCancelsQueuedMessages() async throws {
        let fixtures = TestFixtures()

        // Get a real messaging service from the cache
        let unusedInboxCache = UnusedConversationCache(
            keychainService: fixtures.keychainService,
            identityStore: fixtures.identityStore,
            platformProviders: testPlatformProviders
        )
        let (messagingService, _) = await unusedInboxCache.consumeOrCreateMessagingService(
            databaseWriter: fixtures.databaseManager.dbWriter,
            databaseReader: fixtures.databaseManager.dbReader,
            environment: testEnvironment
        )

        let stateMachine = ConversationStateMachine(
            inboxStateManager: messagingService.inboxStateManager,
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
        let unusedInboxCache = UnusedConversationCache(
            keychainService: fixtures.keychainService,
            identityStore: fixtures.identityStore,
            platformProviders: testPlatformProviders
        )
        let (messagingService, _) = await unusedInboxCache.consumeOrCreateMessagingService(
            databaseWriter: fixtures.databaseManager.dbWriter,
            databaseReader: fixtures.databaseManager.dbReader,
            environment: testEnvironment
        )

        // First create a conversation so we have a valid conversationId
        let createStateMachine = ConversationStateMachine(
            inboxStateManager: messagingService.inboxStateManager,
            identityStore: fixtures.identityStore,
            databaseReader: fixtures.databaseManager.dbReader,
            databaseWriter: fixtures.databaseManager.dbWriter,
            environment: testEnvironment,
            clientConversationId: DBConversation.generateDraftConversationId()
        )

        await createStateMachine.create()

        var createdConversationId: String?
        for await state in await createStateMachine.stateSequence {
            if case .ready(let result) = state {
                createdConversationId = result.conversationId
                break
            }
        }

        guard let conversationId = createdConversationId else {
            Issue.record("Failed to create conversation")
            await messagingService.stopAndDelete()
            try? await fixtures.cleanup()
            return
        }

        // Now test useExisting with a fresh state machine
        let stateMachine = ConversationStateMachine(
            inboxStateManager: messagingService.inboxStateManager,
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
        for await state in await stateMachine.stateSequence {
            switch state {
            case .ready(let readyResult):
                result = readyResult
            case .error(let error):
                Issue.record("UseExisting failed: \(error)")
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
        let unusedInboxCache = UnusedConversationCache(
            keychainService: fixtures.keychainService,
            identityStore: fixtures.identityStore,
            platformProviders: testPlatformProviders
        )
        let (messagingService, _) = await unusedInboxCache.consumeOrCreateMessagingService(
            databaseWriter: fixtures.databaseManager.dbWriter,
            databaseReader: fixtures.databaseManager.dbReader,
            environment: testEnvironment
        )

        // First create a conversation so we have a valid conversationId
        let createStateMachine = ConversationStateMachine(
            inboxStateManager: messagingService.inboxStateManager,
            identityStore: fixtures.identityStore,
            databaseReader: fixtures.databaseManager.dbReader,
            databaseWriter: fixtures.databaseManager.dbWriter,
            environment: testEnvironment,
            clientConversationId: DBConversation.generateDraftConversationId()
        )

        await createStateMachine.create()

        var createdConversationId: String?
        for await state in await createStateMachine.stateSequence {
            if case .ready(let result) = state {
                createdConversationId = result.conversationId
                break
            }
        }

        guard let conversationId = createdConversationId else {
            Issue.record("Failed to create conversation")
            await messagingService.stopAndDelete()
            try? await fixtures.cleanup()
            return
        }

        // Now test useExisting and sending messages with a fresh state machine
        let stateMachine = ConversationStateMachine(
            inboxStateManager: messagingService.inboxStateManager,
            identityStore: fixtures.identityStore,
            databaseReader: fixtures.databaseManager.dbReader,
            databaseWriter: fixtures.databaseManager.dbWriter,
            environment: testEnvironment,
            clientConversationId: DBConversation.generateDraftConversationId()
        )

        // Trigger useExisting
        await stateMachine.useExisting(conversationId: conversationId)

        // Wait for ready state
        for await state in await stateMachine.stateSequence {
            if case .ready = state {
                break
            }
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
        let unusedInboxCache = UnusedConversationCache(
            keychainService: fixtures.keychainService,
            identityStore: fixtures.identityStore,
            platformProviders: testPlatformProviders
        )
        let (messagingService, _) = await unusedInboxCache.consumeOrCreateMessagingService(
            databaseWriter: fixtures.databaseManager.dbWriter,
            databaseReader: fixtures.databaseManager.dbReader,
            environment: testEnvironment
        )

        // First create a conversation
        let createStateMachine = ConversationStateMachine(
            inboxStateManager: messagingService.inboxStateManager,
            identityStore: fixtures.identityStore,
            databaseReader: fixtures.databaseManager.dbReader,
            databaseWriter: fixtures.databaseManager.dbWriter,
            environment: testEnvironment,
            clientConversationId: DBConversation.generateDraftConversationId()
        )

        await createStateMachine.create()

        var createdConversationId: String?
        for await state in await createStateMachine.stateSequence {
            if case .ready(let result) = state {
                createdConversationId = result.conversationId
                break
            }
        }

        guard let conversationId = createdConversationId else {
            Issue.record("Failed to create conversation")
            await messagingService.stopAndDelete()
            try? await fixtures.cleanup()
            return
        }

        // Test useExisting state sequence
        let stateMachine = ConversationStateMachine(
            inboxStateManager: messagingService.inboxStateManager,
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
        let unusedInboxCache = UnusedConversationCache(
            keychainService: fixtures.keychainService,
            identityStore: fixtures.identityStore,
            platformProviders: testPlatformProviders
        )
        let (messagingService, _) = await unusedInboxCache.consumeOrCreateMessagingService(
            databaseWriter: fixtures.databaseManager.dbWriter,
            databaseReader: fixtures.databaseManager.dbReader,
            environment: testEnvironment
        )

        let stateMachine = ConversationStateMachine(
            inboxStateManager: messagingService.inboxStateManager,
            identityStore: fixtures.identityStore,
            databaseReader: fixtures.databaseManager.dbReader,
            databaseWriter: fixtures.databaseManager.dbWriter,
            environment: testEnvironment,
            clientConversationId: DBConversation.generateDraftConversationId()
        )

        // Create conversation first
        await stateMachine.create()

        var conversationId: String?
        for await state in await stateMachine.stateSequence {
            if case .ready(let result) = state {
                conversationId = result.conversationId
                break
            }
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
        for await state in await stateMachine.stateSequence {
            if case .uninitialized = state {
                break
            }
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

    // MARK: - Network Disconnection Tests

    @Test("Messages sync after network reconnection")
    func testMessageSyncAfterNetworkReconnection() async throws {
        // Create separate fixtures for inviter and joiner so they have different databases
        let inviterFixtures = TestFixtures()
        let joinerFixtures = TestFixtures()

        // Create two mock network monitors - both starting connected
        let inviterNetworkMonitor = MockNetworkMonitor(initialStatus: .connected(.wifi))
        let joinerNetworkMonitor = MockNetworkMonitor(initialStatus: .connected(.wifi))

        // Setup inviter messaging service with mock network monitor
        let inviterOperation = AuthorizeInboxOperation.register(
            identityStore: inviterFixtures.identityStore,
            databaseReader: inviterFixtures.databaseManager.dbReader,
            databaseWriter: inviterFixtures.databaseManager.dbWriter,
            networkMonitor: inviterNetworkMonitor,
            environment: testEnvironment,
            platformProviders: testPlatformProviders
        )

        let inviterMessagingService = MessagingService(
            authorizationOperation: inviterOperation,
            databaseWriter: inviterFixtures.databaseManager.dbWriter,
            databaseReader: inviterFixtures.databaseManager.dbReader,
            identityStore: inviterFixtures.identityStore,
            environment: testEnvironment,
            backgroundUploadManager: UnavailableBackgroundUploadManager()
        )

        let inviterStateMachine = ConversationStateMachine(
            inboxStateManager: inviterMessagingService.inboxStateManager,
            identityStore: inviterFixtures.identityStore,
            databaseReader: inviterFixtures.databaseManager.dbReader,
            databaseWriter: inviterFixtures.databaseManager.dbWriter,
            environment: testEnvironment,
            clientConversationId: DBConversation.generateDraftConversationId()
        )

        // Create conversation as inviter
        await inviterStateMachine.create()

        // Wait for inviter conversation to be ready
        // XMTP publish() can be slow in CI, so use a generous timeout
        var inviterConversationId: String?
        do {
            inviterConversationId = try await withTimeout(seconds: 60) {
                for await state in await inviterStateMachine.stateSequence {
                    if case .ready(let result) = state {
                        return result.conversationId
                    }
                }
                throw TestError.timeout("Inviter conversation never reached ready state")
            }
        } catch {
            Issue.record("Inviter failed to create conversation: \(error)")
            await inviterMessagingService.stopAndDelete()
            try? await inviterFixtures.cleanup()
            return
        }

        guard let inviterConvId = inviterConversationId else {
            Issue.record("No inviter conversation ID")
            await inviterMessagingService.stopAndDelete()
            try? await inviterFixtures.cleanup()
            return
        }

        // Fetch the invite
        let invite = try await inviterFixtures.databaseManager.dbReader.read { db in
            try DBInvite
                .filter(DBInvite.Columns.conversationId == inviterConvId)
                .fetchOne(db)?
                .hydrateInvite()
        }

        guard let invite else {
            Issue.record("Could not fetch invite")
            await inviterMessagingService.stopAndDelete()
            try? await inviterFixtures.cleanup()
            return
        }

        Log.info("Inviter created conversation with invite: \(invite.urlSlug)")

        // Wait for inviter's sync streams to be fully ready before joiner connects
        // This prevents a race condition where the joiner sends a DM before the inviter's
        // message stream is connected to receive it
        try await waitUntil(timeout: .seconds(10)) {
            await inviterMessagingService.inboxStateManager.isSyncReady
        }

        // Setup joiner messaging service with different network monitor
        let joinerOperation = AuthorizeInboxOperation.register(
            identityStore: joinerFixtures.identityStore,
            databaseReader: joinerFixtures.databaseManager.dbReader,
            databaseWriter: joinerFixtures.databaseManager.dbWriter,
            networkMonitor: joinerNetworkMonitor,
            environment: testEnvironment,
            platformProviders: testPlatformProviders
        )

        let joinerMessagingService = MessagingService(
            authorizationOperation: joinerOperation,
            databaseWriter: joinerFixtures.databaseManager.dbWriter,
            databaseReader: joinerFixtures.databaseManager.dbReader,
            identityStore: joinerFixtures.identityStore,
            environment: testEnvironment,
            backgroundUploadManager: UnavailableBackgroundUploadManager()
        )

        // Wait for joiner inbox to be ready before joining
        do {
            _ = try await withTimeout(seconds: 60) {
                try await joinerMessagingService.inboxStateManager.waitForInboxReadyResult()
            }
        } catch {
            Issue.record("Timed out waiting for joiner inbox to be ready: \(error)")
            await inviterMessagingService.stopAndDelete()
            await joinerMessagingService.stopAndDelete()
            try? await inviterFixtures.cleanup()
            try? await joinerFixtures.cleanup()
            return
        }

        // Wait for joiner's sync streams to be ready before joining
        try await waitUntil(timeout: .seconds(10)) {
            await joinerMessagingService.inboxStateManager.isSyncReady
        }

        let joinerStateMachine = ConversationStateMachine(
            inboxStateManager: joinerMessagingService.inboxStateManager,
            identityStore: joinerFixtures.identityStore,
            databaseReader: joinerFixtures.databaseManager.dbReader,
            databaseWriter: joinerFixtures.databaseManager.dbWriter,
            environment: testEnvironment,
            clientConversationId: DBConversation.generateDraftConversationId()
        )

        // Join conversation as joiner
        await joinerStateMachine.join(inviteCode: invite.urlSlug)

        // Wait for joiner to be ready
        // Note: Increased timeout from 60s to 90s for CI reliability with ephemeral Fly.io backends
        var joinerConversationId: String?
        do {
            joinerConversationId = try await withTimeout(seconds: 90) {
                for await state in await joinerStateMachine.stateSequence {
                    switch state {
                    case .ready(let result):
                        return result.conversationId
                    case .error(let error):
                        Issue.record("Joiner join failed: \(error)")
                        throw error
                    default:
                        continue
                    }
                }
                throw TestError.timeout("Joiner never reached ready state")
            }
        } catch {
            Issue.record("Joiner failed to join: \(error)")
            await inviterMessagingService.stopAndDelete()
            await joinerMessagingService.stopAndDelete()
            try? await inviterFixtures.cleanup()
            try? await joinerFixtures.cleanup()
            return
        }

        guard let joinerConvId = joinerConversationId else {
            Issue.record("Joiner did not join conversation")
            await inviterMessagingService.stopAndDelete()
            await joinerMessagingService.stopAndDelete()
            try? await inviterFixtures.cleanup()
            try? await joinerFixtures.cleanup()
            return
        }

        Log.info("Joiner joined conversation: \(joinerConvId)")

        // Simulate network disconnection for inviter
        Log.info("Simulating network disconnection for inviter...")
        await inviterNetworkMonitor.simulateDisconnection()

        // Wait for pause to take effect
        try await Task.sleep(for: .seconds(2))

        Log.info("Inviter network disconnected, sending messages from joiner...")

        // Send 10 messages from joiner while inviter is offline
        let messageTexts = [
            "Message 1", "Message 2", "Message 3", "Message 4", "Message 5",
            "Message 6", "Message 7", "Message 8", "Message 9", "Message 10"
        ]

        for text in messageTexts {
            await joinerStateMachine.sendMessage(text: text)
        }

        Log.info("Sent \(messageTexts.count) messages from joiner")

        // Wait for messages to be processed and saved by joiner
        try await Task.sleep(for: .seconds(3))

        // Verify messages were saved in joiner's database and collect message IDs
        let joinerMessages = try await joinerFixtures.databaseManager.dbReader.read { db in
            try DBMessage
                .filter(DBMessage.Columns.conversationId == joinerConvId)
                .order(DBMessage.Columns.dateNs.asc)
                .fetchAll(db)
        }
            .filter { message in
                guard let text = message.text else {
                    return false
                }
                return messageTexts.contains(text)
            }

        Log.info("Joiner has \(joinerMessages.count) messages in database")
        #expect(joinerMessages.count == messageTexts.count, "Joiner should have sent all messages")

        // Collect message IDs from joiner to verify they sync to inviter
        let joinerMessageIds = Set(joinerMessages.map { $0.id })

        // Reconnect inviter's network
        Log.info("Simulating network reconnection for inviter...")
        await inviterNetworkMonitor.simulateConnection(type: .wifi)

        // Wait for reconnection and sync to complete
        try await Task.sleep(for: .seconds(2))

        Log.info("Inviter network reconnected, waiting for messages to sync...")

        // Poll for messages in inviter's database
        var inviterMessageIds = Set<String>()
        let timeout = ContinuousClock.now + .seconds(30)

        while ContinuousClock.now < timeout {
            let inviterMessages = try await inviterFixtures.databaseManager.dbReader.read { db in
                try DBMessage
                    .filter(DBMessage.Columns.conversationId == inviterConvId)
                    .fetchAll(db)
            }

            inviterMessageIds = Set(inviterMessages.map { $0.id })

            // Check if all joiner message IDs exist in inviter's database
            if joinerMessageIds.isSubset(of: inviterMessageIds) {
                break
            }

            try await Task.sleep(for: .milliseconds(500))
        }

        Log.info("Inviter has \(inviterMessageIds.count) messages in database")

        // Verify all joiner message IDs exist in inviter's database
        #expect(joinerMessageIds.isSubset(of: inviterMessageIds), "All joiner message IDs should exist in inviter's database after sync")

        // Log which message IDs were found
        let foundCount = joinerMessageIds.intersection(inviterMessageIds).count
        Log.info("Found \(foundCount) of \(joinerMessageIds.count) joiner message IDs in inviter's database")

        Log.info("Test completed successfully - all messages synced after reconnection")

        // Clean up
        await inviterMessagingService.stopAndDelete()
        await joinerMessagingService.stopAndDelete()
        try? await inviterFixtures.cleanup()
        try? await joinerFixtures.cleanup()
    }
}
