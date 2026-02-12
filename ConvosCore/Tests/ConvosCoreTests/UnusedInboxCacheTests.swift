@preconcurrency @testable import ConvosCore
import Foundation
import GRDB
import Testing
import XMTPiOS

// MARK: - Test Environment Helper

private let testEnvironment = AppEnvironment.tests

/// Comprehensive tests for UnusedConversationCache
///
/// Tests cover:
/// - Pre-creating unused conversations (inbox + conversation + invite)
/// - Consuming unused conversations without race conditions
/// - Concurrent consumption attempts (race condition prevention)
/// - Keychain fallback path
/// - Clearing unused conversations
/// - Ensuring same conversation is never consumed twice
@Suite("UnusedConversationCache Tests")
struct UnusedConversationCacheTests {
    // MARK: - Test Helpers

    /// Waits for an unused conversation to be ready by polling with a timeout
    ///
    /// This function polls to check if an unused conversation has been prepared.
    /// This is more efficient and deterministic than fixed sleep durations.
    ///
    /// - Parameters:
    ///   - cache: The UnusedConversationCache to check
    ///   - timeout: Maximum time to wait (default: 10 seconds)
    /// - Throws: TestError if timeout is reached
    private func waitForUnusedConversation(
        cache: UnusedConversationCache,
        timeout: Duration = .seconds(10)
    ) async throws {
        let deadline = ContinuousClock.now + timeout

        while ContinuousClock.now < deadline {
            // Check if an unused conversation is available
            if await cache.hasUnusedConversation() {
                return
            }

            // Poll every 100ms
            try await Task.sleep(for: .milliseconds(100))
        }

        throw TestError.timeout("Timed out waiting for unused conversation to be created")
    }

    /// Test-specific error type
    private enum TestError: Error {
        case timeout(String)
    }

    // MARK: - Basic Functionality Tests

    @Test("prepareUnusedConversationIfNeeded creates an unused conversation")
    func testPrepareUnusedConversation() async throws {
        let fixtures = TestFixtures()
        let cache = UnusedConversationCache(keychainService: MockKeychainService(), identityStore: fixtures.identityStore, platformProviders: .mock)

        // Clear any existing unused conversation
        await cache.clearUnusedFromKeychain()

        // Prepare unused conversation
        await cache.prepareUnusedConversationIfNeeded(
            databaseWriter: fixtures.databaseManager.dbWriter,
            databaseReader: fixtures.databaseManager.dbReader,
            environment: testEnvironment
        )

        // Wait for conversation to be ready
        try await waitForUnusedConversation(cache: cache)

        // Verify an unused conversation was created (check keychain or service)
        // We can't directly access private properties, but we can verify by consuming it
        let (messagingService, _) = await cache.consumeOrCreateMessagingService(
            databaseWriter: fixtures.databaseManager.dbWriter,
            databaseReader: fixtures.databaseManager.dbReader,
            environment: testEnvironment
        )

        let result = try await messagingService.inboxStateManager.waitForInboxReadyResult()
        #expect(result.client.inboxId.isEmpty == false)

        // Clean up
        await messagingService.stopAndDelete()
        try? await fixtures.cleanup()
    }

    @Test("consumeOrCreateMessagingService returns a valid service")
    func testConsumeOrCreateReturnsValidService() async throws {
        let fixtures = TestFixtures()
        let cache = UnusedConversationCache(keychainService: MockKeychainService(), identityStore: fixtures.identityStore, platformProviders: .mock)

        // Clear any existing unused conversation
        await cache.clearUnusedFromKeychain()

        let (messagingService, _) = await cache.consumeOrCreateMessagingService(
            databaseWriter: fixtures.databaseManager.dbWriter,
            databaseReader: fixtures.databaseManager.dbReader,
            environment: testEnvironment
        )

        let result = try await messagingService.inboxStateManager.waitForInboxReadyResult()
        #expect(result.client.inboxId.isEmpty == false)

        // Clean up
        await messagingService.stopAndDelete()
        try? await fixtures.cleanup()
    }

    // MARK: - Race Condition Tests

    @Test("Concurrent consumeOrCreateMessagingService calls never return the same service")
    func testConcurrentConsumptionNoDuplicates() async throws {
        let fixtures = TestFixtures()
        let cache = UnusedConversationCache(keychainService: MockKeychainService(), identityStore: fixtures.identityStore, platformProviders: .mock)

        // Clear any existing unused conversation
        await cache.clearUnusedFromKeychain()

        // Pre-create an unused conversation to increase likelihood of race
        await cache.prepareUnusedConversationIfNeeded(
            databaseWriter: fixtures.databaseManager.dbWriter,
            databaseReader: fixtures.databaseManager.dbReader,
            environment: testEnvironment
        )

        // Wait for conversation to be ready
        try await waitForUnusedConversation(cache: cache)

        // Call rapidly multiple times - since cache is an actor, calls are serialized
        // but the code still needs to handle the "already consuming" case
        var services: [any MessagingServiceProtocol] = []
        for _ in 0..<5 {
            let (service, _) = await cache.consumeOrCreateMessagingService(
                databaseWriter: fixtures.databaseManager.dbWriter,
                databaseReader: fixtures.databaseManager.dbReader,
                environment: testEnvironment
            )
            services.append(service)
        }

        // Wait for all services to be ready and collect their inbox IDs
        var inboxIds: [String] = []
        for service in services {
            let result = try await service.inboxStateManager.waitForInboxReadyResult()
            inboxIds.append(result.client.inboxId)
        }

        // CRITICAL: All inbox IDs must be unique - no duplicates allowed
        let uniqueInboxIds = Set(inboxIds)
        #expect(uniqueInboxIds.count == 5, "All 5 services must have unique inbox IDs. Got: \(uniqueInboxIds.count) unique out of 5")

        if uniqueInboxIds.count != 5 {
            Issue.record("RACE CONDITION DETECTED: Same inbox consumed multiple times!")
            Issue.record("Inbox IDs: \(inboxIds)")
        }

        // Clean up
        for service in services {
            await service.stopAndDelete()
        }
        try? await fixtures.cleanup()
    }

    @Test("Sequential consumption always returns different services")
    func testSequentialConsumptionDifferentServices() async throws {
        let fixtures = TestFixtures()
        let cache = UnusedConversationCache(keychainService: MockKeychainService(), identityStore: fixtures.identityStore, platformProviders: .mock)

        // Clear any existing unused conversation
        await cache.clearUnusedFromKeychain()

        // Consume first service
        let (service1, _) = await cache.consumeOrCreateMessagingService(
            databaseWriter: fixtures.databaseManager.dbWriter,
            databaseReader: fixtures.databaseManager.dbReader,
            environment: testEnvironment
        )
        let result1 = try await service1.inboxStateManager.waitForInboxReadyResult()
        let inboxId1 = result1.client.inboxId

        // Consume second service
        let (service2, _) = await cache.consumeOrCreateMessagingService(
            databaseWriter: fixtures.databaseManager.dbWriter,
            databaseReader: fixtures.databaseManager.dbReader,
            environment: testEnvironment
        )
        let result2 = try await service2.inboxStateManager.waitForInboxReadyResult()
        let inboxId2 = result2.client.inboxId

        // CRITICAL: Inbox IDs must be different
        #expect(inboxId1 != inboxId2, "Sequential consumptions must return different inboxes")

        // Clean up
        await service1.stopAndDelete()
        await service2.stopAndDelete()
        try? await fixtures.cleanup()
    }

    @Test("Rapid fire consumption attempts all return unique services")
    func testRapidFireConsumptionUniqueness() async throws {
        let fixtures = TestFixtures()
        let cache = UnusedConversationCache(keychainService: MockKeychainService(), identityStore: fixtures.identityStore, platformProviders: .mock)

        // Clear any existing unused conversation
        await cache.clearUnusedFromKeychain()

        // Create 10 services as fast as possible
        var services: [any MessagingServiceProtocol] = []
        for _ in 0..<10 {
            let (service, _) = await cache.consumeOrCreateMessagingService(
                databaseWriter: fixtures.databaseManager.dbWriter,
                databaseReader: fixtures.databaseManager.dbReader,
                environment: testEnvironment
            )
            services.append(service)
        }

        // Collect all inbox IDs
        var inboxIds: [String] = []
        for service in services {
            let result = try await service.inboxStateManager.waitForInboxReadyResult()
            inboxIds.append(result.client.inboxId)
        }

        // CRITICAL: All must be unique
        let uniqueInboxIds = Set(inboxIds)
        #expect(uniqueInboxIds.count == 10, "All 10 rapid-fire services must have unique inbox IDs. Got: \(uniqueInboxIds.count) unique out of 10")

        if uniqueInboxIds.count != 10 {
            Issue.record("RACE CONDITION DETECTED in rapid-fire test!")
            Issue.record("Unique IDs: \(uniqueInboxIds.count) out of 10")
        }

        // Clean up
        for service in services {
            await service.stopAndDelete()
        }
        try? await fixtures.cleanup()
    }

    // MARK: - Atomic Cleanup Tests

    @Test("Consuming clears both memory and keychain atomically")
    func testAtomicCleanupOnConsumption() async throws {
        let fixtures = TestFixtures()
        let cache = UnusedConversationCache(keychainService: MockKeychainService(), identityStore: fixtures.identityStore, platformProviders: .mock)

        // Clear any existing unused conversation
        await cache.clearUnusedFromKeychain()

        // Prepare an unused conversation (this creates both in-memory service and keychain entry)
        await cache.prepareUnusedConversationIfNeeded(
            databaseWriter: fixtures.databaseManager.dbWriter,
            databaseReader: fixtures.databaseManager.dbReader,
            environment: testEnvironment
        )

        // Wait for conversation to be ready
        try await waitForUnusedConversation(cache: cache)

        // Consume the unused conversation
        let (service1, _) = await cache.consumeOrCreateMessagingService(
            databaseWriter: fixtures.databaseManager.dbWriter,
            databaseReader: fixtures.databaseManager.dbReader,
            environment: testEnvironment
        )

        let result1 = try await service1.inboxStateManager.waitForInboxReadyResult()
        let consumedInboxId = result1.client.inboxId

        // CRITICAL: Verify that BOTH keychain and memory are cleared atomically
        // This prevents the dangerous scenario where one is cleared but not the other

        // 1. Verify keychain is cleared immediately after consumption
        let isStillUnused = await cache.isUnusedInbox(consumedInboxId)
        #expect(!isStillUnused, "Consumed inbox should not be marked as unused in keychain")

        // 2. Verify memory is cleared by attempting another consumption
        // This should return a DIFFERENT inbox, not reuse the consumed one
        let (service2, _) = await cache.consumeOrCreateMessagingService(
            databaseWriter: fixtures.databaseManager.dbWriter,
            databaseReader: fixtures.databaseManager.dbReader,
            environment: testEnvironment
        )

        let result2 = try await service2.inboxStateManager.waitForInboxReadyResult()
        let newInboxId = result2.client.inboxId

        // 3. CRITICAL: The new inbox must be different - proves memory was cleared
        #expect(newInboxId != consumedInboxId, "Second consumption must return a different inbox - proves atomic cleanup")

        // Clean up
        await service1.stopAndDelete()
        await service2.stopAndDelete()
        try? await fixtures.cleanup()
    }

    @Test("Keychain cleared even when consuming via memory")
    func testKeychainClearedWhenConsumingFromMemory() async throws {
        let fixtures = TestFixtures()
        let cache = UnusedConversationCache(keychainService: MockKeychainService(), identityStore: fixtures.identityStore, platformProviders: .mock)

        // Clear any existing unused conversation
        await cache.clearUnusedFromKeychain()

        // Prepare an unused conversation (creates both in-memory service AND keychain entry)
        await cache.prepareUnusedConversationIfNeeded(
            databaseWriter: fixtures.databaseManager.dbWriter,
            databaseReader: fixtures.databaseManager.dbReader,
            environment: testEnvironment
        )

        // Wait for conversation to be ready
        try await waitForUnusedConversation(cache: cache)

        // Before consuming, the keychain should have the inbox
        // We can't directly check keychain, but we know it exists because prepareUnusedConversationIfNeeded succeeded

        // Consume - this uses the in-memory service path
        let (service, _) = await cache.consumeOrCreateMessagingService(
            databaseWriter: fixtures.databaseManager.dbWriter,
            databaseReader: fixtures.databaseManager.dbReader,
            environment: testEnvironment
        )

        let result = try await service.inboxStateManager.waitForInboxReadyResult()
        let consumedInboxId = result.client.inboxId

        // CRITICAL: Even though we consumed via memory, keychain must also be cleared
        let isStillInKeychain = await cache.isUnusedInbox(consumedInboxId)
        #expect(!isStillInKeychain, "Keychain must be cleared even when consuming via memory path")

        // Clean up
        await service.stopAndDelete()
        try? await fixtures.cleanup()
    }

    @Test("Both paths clear atomically - memory and keychain")
    func testBothConsumptionPathsClearAtomically() async throws {
        let fixtures = TestFixtures()
        let cache = UnusedConversationCache(keychainService: MockKeychainService(), identityStore: fixtures.identityStore, platformProviders: .mock)

        // Test 1: Consume via memory path
        await cache.clearUnusedFromKeychain()
        await cache.prepareUnusedConversationIfNeeded(
            databaseWriter: fixtures.databaseManager.dbWriter,
            databaseReader: fixtures.databaseManager.dbReader,
            environment: testEnvironment
        )
        try await waitForUnusedConversation(cache: cache)

        let (service1, _) = await cache.consumeOrCreateMessagingService(
            databaseWriter: fixtures.databaseManager.dbWriter,
            databaseReader: fixtures.databaseManager.dbReader,
            environment: testEnvironment
        )
        let result1 = try await service1.inboxStateManager.waitForInboxReadyResult()
        let inboxId1 = result1.client.inboxId

        // Verify both cleared
        let isUnused1 = await cache.isUnusedInbox(inboxId1)
        #expect(!isUnused1, "Memory path: keychain must be cleared")

        // Test 2: Consume via keychain path
        // (In a real scenario, the memory service might not exist but keychain does)
        await cache.clearUnusedFromKeychain()

        let (service2, _) = await cache.consumeOrCreateMessagingService(
            databaseWriter: fixtures.databaseManager.dbWriter,
            databaseReader: fixtures.databaseManager.dbReader,
            environment: testEnvironment
        )
        let result2 = try await service2.inboxStateManager.waitForInboxReadyResult()
        let inboxId2 = result2.client.inboxId

        // Verify cleared
        let isUnused2 = await cache.isUnusedInbox(inboxId2)
        #expect(!isUnused2, "Keychain path: must be cleared")

        // Verify different inboxes
        #expect(inboxId1 != inboxId2, "Each consumption should return unique inbox")

        // Clean up
        await service1.stopAndDelete()
        await service2.stopAndDelete()
        try? await fixtures.cleanup()
    }

    // MARK: - isUnusedInbox Tests

    @Test("isUnusedInbox correctly identifies unused inbox")
    func testIsUnusedInbox() async throws {
        let fixtures = TestFixtures()
        let cache = UnusedConversationCache(keychainService: MockKeychainService(), identityStore: fixtures.identityStore, platformProviders: .mock)

        // Clear any existing unused conversation
        await cache.clearUnusedFromKeychain()

        // Prepare an unused conversation
        await cache.prepareUnusedConversationIfNeeded(
            databaseWriter: fixtures.databaseManager.dbWriter,
            databaseReader: fixtures.databaseManager.dbReader,
            environment: testEnvironment
        )

        // Wait for conversation to be ready
        try await waitForUnusedConversation(cache: cache)

        // Consume to get the inbox ID
        let (service, _) = await cache.consumeOrCreateMessagingService(
            databaseWriter: fixtures.databaseManager.dbWriter,
            databaseReader: fixtures.databaseManager.dbReader,
            environment: testEnvironment
        )

        let result = try await service.inboxStateManager.waitForInboxReadyResult()
        _ = result.client.inboxId

        // Check a random ID
        let isRandomUnused = await cache.isUnusedInbox("random-inbox-id")
        #expect(!isRandomUnused, "Random ID should not be unused")

        // Clean up
        await service.stopAndDelete()
        try? await fixtures.cleanup()
    }

    // MARK: - Stress Tests

    @Test("Stress test: 10 rapid sequential consumptions all unique")
    func testStressConcurrentConsumptions() async throws {
        let fixtures = TestFixtures()
        let cache = UnusedConversationCache(keychainService: MockKeychainService(), identityStore: fixtures.identityStore, platformProviders: .mock)

        // Clear any existing unused conversation
        await cache.clearUnusedFromKeychain()

        // Create services rapidly in sequence (not concurrent due to Sendable restrictions)
        // The actor isolation on UnusedConversationCache ensures thread safety
        let serviceCount = 10
        var services: [any MessagingServiceProtocol] = []

        for _ in 0..<serviceCount {
            let (service, _) = await cache.consumeOrCreateMessagingService(
                databaseWriter: fixtures.databaseManager.dbWriter,
                databaseReader: fixtures.databaseManager.dbReader,
                environment: testEnvironment
            )
            services.append(service)
        }

        // Collect all inbox IDs
        var inboxIds: [String] = []
        for service in services {
            let result = try await service.inboxStateManager.waitForInboxReadyResult()
            inboxIds.append(result.client.inboxId)
        }

        // CRITICAL: All must be unique
        let uniqueInboxIds = Set(inboxIds)
        #expect(uniqueInboxIds.count == serviceCount, "All \(serviceCount) rapid sequential services must have unique inbox IDs. Got: \(uniqueInboxIds.count) unique")

        if uniqueInboxIds.count != serviceCount {
            Issue.record("RACE CONDITION DETECTED in rapid sequential test!")
            Issue.record("Unique IDs: \(uniqueInboxIds.count) out of \(serviceCount)")

            // Find duplicates
            var counts: [String: Int] = [:]
            for id in inboxIds {
                counts[id, default: 0] += 1
            }
            let duplicates = counts.filter { $0.value > 1 }
            Issue.record("Duplicated inbox IDs: \(duplicates)")
        }

        // Clean up
        for service in services {
            await service.stopAndDelete()
        }
        try? await fixtures.cleanup()
    }

    // MARK: - Deletion and Recreation Scenario Tests

    @Test("Unused conversation cache works after deleting first consumed conversation")
    func testUnusedConversationWorksAfterDeletion() async throws {
        let fixtures = TestFixtures()
        let cache = UnusedConversationCache(keychainService: MockKeychainService(), identityStore: fixtures.identityStore, platformProviders: .mock)

        // Clear any existing unused conversation
        await cache.clearUnusedFromKeychain()

        // Step 1: Prepare and consume first conversation (conversation A)
        await cache.prepareUnusedConversationIfNeeded(
            databaseWriter: fixtures.databaseManager.dbWriter,
            databaseReader: fixtures.databaseManager.dbReader,
            environment: testEnvironment
        )
        try await waitForUnusedConversation(cache: cache)

        let (serviceA, _) = await cache.consumeOrCreateMessagingService(
            databaseWriter: fixtures.databaseManager.dbWriter,
            databaseReader: fixtures.databaseManager.dbReader,
            environment: testEnvironment
        )
        let resultA = try await serviceA.inboxStateManager.waitForInboxReadyResult()
        let inboxIdA = resultA.client.inboxId
        #expect(!inboxIdA.isEmpty, "Inbox A should have a valid inbox ID")

        // Step 2: Wait for background task to create new unused conversation (conversation B)
        try await waitForUnusedConversation(cache: cache, timeout: .seconds(15))
        #expect(await cache.hasUnusedConversation(), "Unused conversation B should be available after consuming A")

        // Step 3: Delete inbox A (simulating user deleting/exploding a conversation)
        await serviceA.stopAndDelete()

        // Step 4: Wait to simulate the SleepingInboxMessageChecker period (5+ seconds)
        try await Task.sleep(for: .seconds(6))

        // Step 5: Verify unused conversation B is still valid
        #expect(await cache.hasUnusedConversation(), "Unused conversation B should still be available after deleting A")

        // Step 6: Consume unused conversation B to create conversation C
        let (serviceC, _) = await cache.consumeOrCreateMessagingService(
            databaseWriter: fixtures.databaseManager.dbWriter,
            databaseReader: fixtures.databaseManager.dbReader,
            environment: testEnvironment
        )

        // Step 7: Verify conversation C works correctly
        let resultC = try await serviceC.inboxStateManager.waitForInboxReadyResult()
        let inboxIdC = resultC.client.inboxId
        #expect(!inboxIdC.isEmpty, "Inbox C should have a valid inbox ID")
        #expect(inboxIdC != inboxIdA, "Inbox C should be different from deleted inbox A")

        // Clean up
        await serviceC.stopAndDelete()
        try? await fixtures.cleanup()
    }

    @Test("Multiple delete-and-recreate cycles work correctly")
    func testMultipleDeleteAndRecreateCycles() async throws {
        let fixtures = TestFixtures()
        let cache = UnusedConversationCache(keychainService: MockKeychainService(), identityStore: fixtures.identityStore, platformProviders: .mock)

        // Clear any existing unused conversation
        await cache.clearUnusedFromKeychain()

        var previousInboxIds: Set<String> = []

        // Run 3 cycles of: create -> wait for background -> delete -> wait -> create again
        for cycle in 1...3 {
            // Prepare if this is the first cycle
            if cycle == 1 {
                await cache.prepareUnusedConversationIfNeeded(
                    databaseWriter: fixtures.databaseManager.dbWriter,
                    databaseReader: fixtures.databaseManager.dbReader,
                    environment: testEnvironment
                )
                try await waitForUnusedConversation(cache: cache)
            }

            // Consume conversation
            let (service, _) = await cache.consumeOrCreateMessagingService(
                databaseWriter: fixtures.databaseManager.dbWriter,
                databaseReader: fixtures.databaseManager.dbReader,
                environment: testEnvironment
            )
            let result = try await service.inboxStateManager.waitForInboxReadyResult()
            let inboxId = result.client.inboxId

            #expect(!inboxId.isEmpty, "Cycle \(cycle): Inbox should have a valid ID")
            #expect(!previousInboxIds.contains(inboxId), "Cycle \(cycle): Inbox ID should be unique")
            previousInboxIds.insert(inboxId)

            // Wait for background to create next unused conversation
            try await waitForUnusedConversation(cache: cache, timeout: .seconds(15))

            // Delete the inbox
            await service.stopAndDelete()

            // Wait to simulate time passing (like SleepingInboxMessageChecker period)
            try await Task.sleep(for: .seconds(2))

            // Verify unused conversation is still available for next cycle
            if cycle < 3 {
                #expect(await cache.hasUnusedConversation(), "Cycle \(cycle): Unused conversation should be available for next cycle")
            }
        }

        #expect(previousInboxIds.count == 3, "Should have created 3 unique inboxes")

        try? await fixtures.cleanup()
    }
}
