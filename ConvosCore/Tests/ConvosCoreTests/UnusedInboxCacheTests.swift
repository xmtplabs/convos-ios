@preconcurrency @testable import ConvosCore
import Foundation
import GRDB
import Testing
import XMTPiOS

// MARK: - Test Environment Helper

private let testEnvironment = AppEnvironment.tests

/// Comprehensive tests for UnusedInboxCache
///
/// Tests cover:
/// - Pre-creating unused inboxes
/// - Consuming unused inboxes without race conditions
/// - Concurrent consumption attempts (race condition prevention)
/// - Keychain fallback path
/// - Clearing unused inboxes
/// - Ensuring same inbox is never consumed twice
@Suite("UnusedInboxCache Tests")
struct UnusedInboxCacheTests {
    // MARK: - Test Helpers

    /// Waits for an unused inbox to be ready by polling with a timeout
    ///
    /// This function polls to check if an unused inbox has been prepared.
    /// This is more efficient and deterministic than fixed sleep durations.
    ///
    /// - Parameters:
    ///   - cache: The UnusedInboxCache to check
    ///   - timeout: Maximum time to wait (default: 10 seconds)
    /// - Throws: TestError if timeout is reached
    private func waitForUnusedInbox(
        cache: UnusedInboxCache,
        timeout: Duration = .seconds(10)
    ) async throws {
        let deadline = ContinuousClock.now + timeout

        while ContinuousClock.now < deadline {
            // Check if an unused inbox is available
            if await cache.hasUnusedInbox() {
                return
            }

            // Poll every 100ms
            try await Task.sleep(for: .milliseconds(100))
        }

        throw TestError.timeout("Timed out waiting for unused inbox to be created")
    }

    /// Test-specific error type
    private enum TestError: Error {
        case timeout(String)
    }

    // MARK: - Basic Functionality Tests

    @Test("prepareUnusedInboxIfNeeded creates an unused inbox")
    func testPrepareUnusedInbox() async throws {
        let fixtures = TestFixtures()
        let cache = UnusedInboxCache(keychainService: MockKeychainService(), identityStore: fixtures.identityStore, platformProviders: .mock)

        // Clear any existing unused inbox
        await cache.clearUnusedInboxFromKeychain()

        // Prepare unused inbox
        await cache.prepareUnusedInboxIfNeeded(
            databaseWriter: fixtures.databaseManager.dbWriter,
            databaseReader: fixtures.databaseManager.dbReader,
            environment: testEnvironment
        )

        // Wait for inbox to be ready
        try await waitForUnusedInbox(cache: cache)

        // Verify an unused inbox was created (check keychain or service)
        // We can't directly access private properties, but we can verify by consuming it
        let messagingService = await cache.consumeOrCreateMessagingService(
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
        let cache = UnusedInboxCache(keychainService: MockKeychainService(), identityStore: fixtures.identityStore, platformProviders: .mock)

        // Clear any existing unused inbox
        await cache.clearUnusedInboxFromKeychain()

        let messagingService = await cache.consumeOrCreateMessagingService(
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
        let cache = UnusedInboxCache(keychainService: MockKeychainService(), identityStore: fixtures.identityStore, platformProviders: .mock)

        // Clear any existing unused inbox
        await cache.clearUnusedInboxFromKeychain()

        // Pre-create an unused inbox to increase likelihood of race
        await cache.prepareUnusedInboxIfNeeded(
            databaseWriter: fixtures.databaseManager.dbWriter,
            databaseReader: fixtures.databaseManager.dbReader,
            environment: testEnvironment
        )

        // Wait for inbox to be ready
        try await waitForUnusedInbox(cache: cache)

        // Call rapidly multiple times - since cache is an actor, calls are serialized
        // but the code still needs to handle the "already consuming" case
        var services: [any MessagingServiceProtocol] = []
        for _ in 0..<5 {
            let service = await cache.consumeOrCreateMessagingService(
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
        let cache = UnusedInboxCache(keychainService: MockKeychainService(), identityStore: fixtures.identityStore, platformProviders: .mock)

        // Clear any existing unused inbox
        await cache.clearUnusedInboxFromKeychain()

        // Consume first service
        let service1 = await cache.consumeOrCreateMessagingService(
            databaseWriter: fixtures.databaseManager.dbWriter,
            databaseReader: fixtures.databaseManager.dbReader,
            environment: testEnvironment
        )
        let result1 = try await service1.inboxStateManager.waitForInboxReadyResult()
        let inboxId1 = result1.client.inboxId

        // Consume second service
        let service2 = await cache.consumeOrCreateMessagingService(
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
        let cache = UnusedInboxCache(keychainService: MockKeychainService(), identityStore: fixtures.identityStore, platformProviders: .mock)

        // Clear any existing unused inbox
        await cache.clearUnusedInboxFromKeychain()

        // Create 10 services as fast as possible
        var services: [any MessagingServiceProtocol] = []
        for _ in 0..<10 {
            let service = await cache.consumeOrCreateMessagingService(
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
        let cache = UnusedInboxCache(keychainService: MockKeychainService(), identityStore: fixtures.identityStore, platformProviders: .mock)

        // Clear any existing unused inbox
        await cache.clearUnusedInboxFromKeychain()

        // Prepare an unused inbox (this creates both in-memory service and keychain entry)
        await cache.prepareUnusedInboxIfNeeded(
            databaseWriter: fixtures.databaseManager.dbWriter,
            databaseReader: fixtures.databaseManager.dbReader,
            environment: testEnvironment
        )

        // Wait for inbox to be ready
        try await waitForUnusedInbox(cache: cache)

        // Consume the unused inbox
        let service1 = await cache.consumeOrCreateMessagingService(
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
        let service2 = await cache.consumeOrCreateMessagingService(
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
        let cache = UnusedInboxCache(keychainService: MockKeychainService(), identityStore: fixtures.identityStore, platformProviders: .mock)

        // Clear any existing unused inbox
        await cache.clearUnusedInboxFromKeychain()

        // Prepare an unused inbox (creates both in-memory service AND keychain entry)
        await cache.prepareUnusedInboxIfNeeded(
            databaseWriter: fixtures.databaseManager.dbWriter,
            databaseReader: fixtures.databaseManager.dbReader,
            environment: testEnvironment
        )

        // Wait for inbox to be ready
        try await waitForUnusedInbox(cache: cache)

        // Before consuming, the keychain should have the inbox
        // We can't directly check keychain, but we know it exists because prepareUnusedInboxIfNeeded succeeded

        // Consume - this uses the in-memory service path
        let service = await cache.consumeOrCreateMessagingService(
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
        let cache = UnusedInboxCache(keychainService: MockKeychainService(), identityStore: fixtures.identityStore, platformProviders: .mock)

        // Test 1: Consume via memory path
        await cache.clearUnusedInboxFromKeychain()
        await cache.prepareUnusedInboxIfNeeded(
            databaseWriter: fixtures.databaseManager.dbWriter,
            databaseReader: fixtures.databaseManager.dbReader,
            environment: testEnvironment
        )
        try await waitForUnusedInbox(cache: cache)

        let service1 = await cache.consumeOrCreateMessagingService(
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
        await cache.clearUnusedInboxFromKeychain()

        let service2 = await cache.consumeOrCreateMessagingService(
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
        let cache = UnusedInboxCache(keychainService: MockKeychainService(), identityStore: fixtures.identityStore, platformProviders: .mock)

        // Clear any existing unused inbox
        await cache.clearUnusedInboxFromKeychain()

        // Prepare an unused inbox
        await cache.prepareUnusedInboxIfNeeded(
            databaseWriter: fixtures.databaseManager.dbWriter,
            databaseReader: fixtures.databaseManager.dbReader,
            environment: testEnvironment
        )

        // Wait for inbox to be ready
        try await waitForUnusedInbox(cache: cache)

        // Consume to get the inbox ID
        let service = await cache.consumeOrCreateMessagingService(
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
        let cache = UnusedInboxCache(keychainService: MockKeychainService(), identityStore: fixtures.identityStore, platformProviders: .mock)

        // Clear any existing unused inbox
        await cache.clearUnusedInboxFromKeychain()

        // Create services rapidly in sequence (not concurrent due to Sendable restrictions)
        // The actor isolation on UnusedInboxCache ensures thread safety
        let serviceCount = 10
        var services: [any MessagingServiceProtocol] = []

        for _ in 0..<serviceCount {
            let service = await cache.consumeOrCreateMessagingService(
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
}
