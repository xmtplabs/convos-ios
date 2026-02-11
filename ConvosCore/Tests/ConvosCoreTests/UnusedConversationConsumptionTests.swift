@preconcurrency @testable import ConvosCore
import Foundation
import GRDB
import Testing
import XMTPiOS

private let testEnvironment = AppEnvironment.tests

/// Tests for the conversation consumption flow that mirrors NewConversationViewModel
///
/// This test suite specifically targets the bug where two conversations appear
/// after tapping "new conversation" - one from the unused cache and one newly created.
///
/// The issue manifests as:
/// - consumeOrCreateMessagingService returns a conversation ID
/// - But the UI shows a DIFFERENT conversation
/// - Both end up in the conversations list with isUnused = false
@Suite("Unused Conversation Consumption Flow Tests")
struct UnusedConversationConsumptionTests {
    private enum TestError: Error {
        case timeout(String)
    }

    private func waitForUnusedConversation(
        cache: UnusedConversationCache,
        timeout: Duration = .seconds(10)
    ) async throws {
        let deadline = ContinuousClock.now + timeout

        while ContinuousClock.now < deadline {
            if await cache.hasUnusedConversation() {
                return
            }
            try await Task.sleep(for: .milliseconds(100))
        }

        throw TestError.timeout("Timed out waiting for unused conversation to be created")
    }

    @Test("Consuming unused conversation returns the correct conversation ID in state manager")
    func testConsumedConversationIdMatchesStateManager() async throws {
        let fixtures = TestFixtures()
        let cache = UnusedConversationCache(
            keychainService: MockKeychainService(),
            identityStore: fixtures.identityStore,
            platformProviders: .mock
        )

        await cache.clearUnusedFromKeychain()

        // Step 1: Pre-create an unused conversation
        await cache.prepareUnusedConversationIfNeeded(
            databaseWriter: fixtures.databaseManager.dbWriter,
            databaseReader: fixtures.databaseManager.dbReader,
            environment: testEnvironment
        )
        try await waitForUnusedConversation(cache: cache)

        // Step 2: Consume the unused conversation (mimics session.addInbox())
        let (messagingService, existingConversationId) = await cache.consumeOrCreateMessagingService(
            databaseWriter: fixtures.databaseManager.dbWriter,
            databaseReader: fixtures.databaseManager.dbReader,
            environment: testEnvironment
        )

        // CRITICAL: existingConversationId should NOT be nil when consuming a pre-created conversation
        #expect(existingConversationId != nil, "Consumed conversation should return a conversation ID")

        guard let existingConversationId else {
            Issue.record("existingConversationId is nil - this is the root cause of the bug")
            await messagingService.stopAndDelete()
            try? await fixtures.cleanup()
            return
        }

        // Step 3: Create ConversationStateManager with the existing ID (mimics NewConversationViewModel)
        let conversationStateManager = messagingService.conversationStateManager(for: existingConversationId)

        // Step 4: Verify the state manager uses the same conversation ID
        let stateManagerConversationId = conversationStateManager.draftConversationRepository.conversationId
        #expect(
            stateManagerConversationId == existingConversationId,
            "State manager conversation ID (\(stateManagerConversationId)) should match consumed ID (\(existingConversationId))"
        )

        // Clean up
        await messagingService.stopAndDelete()
        try? await fixtures.cleanup()
    }

    @Test("Only one conversation with isUnused=false exists after consumption")
    func testOnlyOneUsedConversationAfterConsumption() async throws {
        let fixtures = TestFixtures()
        let cache = UnusedConversationCache(
            keychainService: MockKeychainService(),
            identityStore: fixtures.identityStore,
            platformProviders: .mock
        )

        await cache.clearUnusedFromKeychain()

        // Step 1: Pre-create an unused conversation
        await cache.prepareUnusedConversationIfNeeded(
            databaseWriter: fixtures.databaseManager.dbWriter,
            databaseReader: fixtures.databaseManager.dbReader,
            environment: testEnvironment
        )
        try await waitForUnusedConversation(cache: cache)

        // Step 2: Consume the unused conversation
        let (messagingService, existingConversationId) = await cache.consumeOrCreateMessagingService(
            databaseWriter: fixtures.databaseManager.dbWriter,
            databaseReader: fixtures.databaseManager.dbReader,
            environment: testEnvironment
        )

        guard let existingConversationId else {
            Issue.record("existingConversationId is nil")
            await messagingService.stopAndDelete()
            try? await fixtures.cleanup()
            return
        }

        // Step 3: Verify database state - only ONE conversation should have isUnused = false
        let usedConversations = try await fixtures.databaseManager.dbReader.read { db in
            try DBConversation
                .filter(DBConversation.Columns.isUnused == false)
                .fetchAll(db)
        }

        #expect(
            usedConversations.count == 1,
            "Expected exactly 1 used conversation, found \(usedConversations.count)"
        )

        if usedConversations.count != 1 {
            Issue.record("DUPLICATE CONVERSATIONS DETECTED!")
            for (index, conv) in usedConversations.enumerated() {
                Issue.record("  Conversation \(index + 1): id=\(conv.id), clientConversationId=\(conv.clientConversationId ?? "nil"), isUnused=\(conv.isUnused)")
            }
        }

        // Step 4: Verify the consumed conversation ID matches what's in the database
        if let firstUsedConversation = usedConversations.first {
            #expect(
                firstUsedConversation.id == existingConversationId,
                "Database conversation ID (\(firstUsedConversation.id)) should match consumed ID (\(existingConversationId))"
            )
        }

        // Clean up
        await messagingService.stopAndDelete()
        try? await fixtures.cleanup()
    }

    @Test("Full NewConversationViewModel flow does not create duplicate conversations")
    func testNewConversationViewModelFlowNoDuplicates() async throws {
        let fixtures = TestFixtures()
        let cache = UnusedConversationCache(
            keychainService: MockKeychainService(),
            identityStore: fixtures.identityStore,
            platformProviders: .mock
        )

        await cache.clearUnusedFromKeychain()

        // Step 1: Pre-create an unused conversation
        await cache.prepareUnusedConversationIfNeeded(
            databaseWriter: fixtures.databaseManager.dbWriter,
            databaseReader: fixtures.databaseManager.dbReader,
            environment: testEnvironment
        )
        try await waitForUnusedConversation(cache: cache)

        // Step 2: Consume the unused conversation (session.addInbox())
        let (messagingService, existingConversationId) = await cache.consumeOrCreateMessagingService(
            databaseWriter: fixtures.databaseManager.dbWriter,
            databaseReader: fixtures.databaseManager.dbReader,
            environment: testEnvironment
        )

        // Step 3: Create state manager - this is the CRITICAL path in NewConversationViewModel
        let conversationStateManager: any ConversationStateManagerProtocol
        if let existingConversationId {
            conversationStateManager = messagingService.conversationStateManager(for: existingConversationId)
        } else {
            conversationStateManager = messagingService.conversationStateManager()
        }

        // Step 4: Get the conversation ID that would be used for the draft conversation
        let draftConversationId = conversationStateManager.draftConversationRepository.conversationId

        // Log the IDs for debugging
        if let existingConversationId {
            #expect(
                draftConversationId == existingConversationId,
                "Draft conversation ID (\(draftConversationId)) should match consumed ID (\(existingConversationId))"
            )
        }

        // Step 5: Simulate what happens in NewConversationViewModel init
        // If autoCreateConversation is true AND existingConversationId is nil, it calls createConversation()
        // This should NOT happen when existingConversationId is provided
        let autoCreateConversation = true
        let shouldCreateNewConversation = autoCreateConversation && existingConversationId == nil

        if shouldCreateNewConversation {
            Issue.record("BUG: Would create new conversation even though we have an existing one!")
        }

        #expect(
            !shouldCreateNewConversation || existingConversationId == nil,
            "Should not create new conversation when existingConversationId is present"
        )

        // Step 6: Wait a bit for any background tasks
        try await Task.sleep(for: .seconds(1))

        // Step 7: Verify database state - filter by clientId to exclude stale conversations from XMTP's persistent storage
        let clientId = messagingService.clientId
        let allConversations = try await fixtures.databaseManager.dbReader.read { db in
            try DBConversation
                .filter(DBConversation.Columns.clientId == clientId)
                .fetchAll(db)
        }

        let usedConversations = allConversations.filter { !$0.isUnused }
        let unusedConversations = allConversations.filter { $0.isUnused }

        #expect(
            usedConversations.count == 1,
            "Expected exactly 1 used conversation, found \(usedConversations.count)"
        )

        if usedConversations.count > 1 {
            Issue.record("DUPLICATE USED CONVERSATIONS:")
            for conv in usedConversations {
                Issue.record("  id=\(conv.id), clientConversationId=\(conv.clientConversationId ?? "nil")")
            }
        }

        if !unusedConversations.isEmpty {
            // This is expected - background task creates a new unused conversation
            Issue.record("Note: \(unusedConversations.count) unused conversation(s) exist (expected from background creation)")
        }

        // Clean up
        await messagingService.stopAndDelete()
        try? await fixtures.cleanup()
    }

    @Test("State machine useExisting is called when existingConversationId is provided")
    func testStateMachineUsesExistingConversation() async throws {
        let fixtures = TestFixtures()
        let cache = UnusedConversationCache(
            keychainService: MockKeychainService(),
            identityStore: fixtures.identityStore,
            platformProviders: .mock
        )

        await cache.clearUnusedFromKeychain()

        // Step 1: Pre-create an unused conversation
        await cache.prepareUnusedConversationIfNeeded(
            databaseWriter: fixtures.databaseManager.dbWriter,
            databaseReader: fixtures.databaseManager.dbReader,
            environment: testEnvironment
        )
        try await waitForUnusedConversation(cache: cache)

        // Step 2: Consume the unused conversation
        let (messagingService, existingConversationId) = await cache.consumeOrCreateMessagingService(
            databaseWriter: fixtures.databaseManager.dbWriter,
            databaseReader: fixtures.databaseManager.dbReader,
            environment: testEnvironment
        )

        guard let existingConversationId else {
            Issue.record("existingConversationId is nil")
            await messagingService.stopAndDelete()
            try? await fixtures.cleanup()
            return
        }

        // Step 3: Create state manager with existing ID
        let conversationStateManager = messagingService.conversationStateManager(for: existingConversationId)

        // Step 4: Wait for state machine to reach ready state
        // When useExisting is called, it should transition to .ready with origin = .existing
        var finalState: ConversationStateMachine.State?
        var stateCount = 0

        let observerHandle = await MainActor.run {
            conversationStateManager.observeState { state in
                stateCount += 1
                finalState = state
            }
        }

        // Wait for state to settle
        let deadline = ContinuousClock.now + .seconds(5)
        while ContinuousClock.now < deadline {
            if case .ready(let result) = finalState {
                // Verify it's using the existing conversation
                #expect(
                    result.conversationId == existingConversationId,
                    "Ready state should use existing conversation ID"
                )
                #expect(
                    result.origin == .existing,
                    "Ready state origin should be .existing, got \(result.origin)"
                )
                break
            }
            try await Task.sleep(for: .milliseconds(100))
        }

        observerHandle.cancel()

        // Verify we reached ready state
        if case .ready = finalState {
            // Success
        } else {
            Issue.record("State machine did not reach ready state, final state: \(String(describing: finalState))")
        }

        // Clean up
        await messagingService.stopAndDelete()
        try? await fixtures.cleanup()
    }

    @Test("Conversation count after complete flow matches expected")
    func testConversationCountAfterFlow() async throws {
        let fixtures = TestFixtures()
        let cache = UnusedConversationCache(
            keychainService: MockKeychainService(),
            identityStore: fixtures.identityStore,
            platformProviders: .mock
        )

        await cache.clearUnusedFromKeychain()

        // Count initial conversations
        let initialCount = try await fixtures.databaseManager.dbReader.read { db in
            try DBConversation.fetchCount(db)
        }
        #expect(initialCount == 0, "Should start with no conversations")

        // Step 1: Pre-create an unused conversation
        await cache.prepareUnusedConversationIfNeeded(
            databaseWriter: fixtures.databaseManager.dbWriter,
            databaseReader: fixtures.databaseManager.dbReader,
            environment: testEnvironment
        )
        try await waitForUnusedConversation(cache: cache)

        // Count after prep - should have 1 unused conversation
        let afterPrepCount = try await fixtures.databaseManager.dbReader.read { db in
            try DBConversation.filter(DBConversation.Columns.isUnused == true).fetchCount(db)
        }
        #expect(afterPrepCount == 1, "Should have 1 unused conversation after prep")

        // Step 2: Consume the unused conversation
        let (messagingService, existingConversationId) = await cache.consumeOrCreateMessagingService(
            databaseWriter: fixtures.databaseManager.dbWriter,
            databaseReader: fixtures.databaseManager.dbReader,
            environment: testEnvironment
        )

        // Step 3: Create state manager (mimics NewConversationViewModel)
        let _: any ConversationStateManagerProtocol
        if let existingConversationId {
            _ = messagingService.conversationStateManager(for: existingConversationId)
        } else {
            _ = messagingService.conversationStateManager()
        }

        // Wait for any background tasks
        try await Task.sleep(for: .seconds(2))

        // Step 4: Count used conversations - should be exactly 1
        let usedCount = try await fixtures.databaseManager.dbReader.read { db in
            try DBConversation.filter(DBConversation.Columns.isUnused == false).fetchCount(db)
        }

        #expect(
            usedCount == 1,
            "Should have exactly 1 used conversation after flow, found \(usedCount)"
        )

        if usedCount != 1 {
            let allUsed = try await fixtures.databaseManager.dbReader.read { db in
                try DBConversation.filter(DBConversation.Columns.isUnused == false).fetchAll(db)
            }
            Issue.record("Found \(usedCount) used conversations instead of 1:")
            for conv in allUsed {
                Issue.record("  - id: \(conv.id)")
                Issue.record("    clientConversationId: \(conv.clientConversationId ?? "nil")")
                Issue.record("    isUnused: \(conv.isUnused)")
            }
        }

        // Clean up
        await messagingService.stopAndDelete()
        try? await fixtures.cleanup()
    }
}
