@testable import ConvosCore
@testable import ConvosCoreDTU
import Foundation
import GRDB

// MARK: - SequentialMockUnusedConversationCache
//
// Stage 6f: lifted from
// `ConvosCore/Tests/ConvosCoreTests/InboxLifecycleManagerTests.swift`.
// Shared between the migrated `ConsumeInboxOnlyTests`,
// `InboxLifecycleManagerTests`, and `UnusedConversationConsumptionTests`
// so the mock cache lives in one place in the DTU test target.
//
// Each `consume*` call hands out a fresh `MockMessagingService` with
// a deterministic clientId; consumption clears the unused id pair
// until `markNewInboxAvailable()` resets them.

actor SequentialMockUnusedConversationCache: UnusedConversationCacheProtocol {
    private var nextInboxNumber: Int = 1
    private var currentUnusedInboxId: String?
    private var currentUnusedConversationId: String?

    init() {
        currentUnusedInboxId = "unused-inbox-1"
        currentUnusedConversationId = "unused-conversation-1"
    }

    func prepareUnusedConversationIfNeeded(
        databaseWriter: any DatabaseWriter,
        databaseReader: any DatabaseReader,
        environment: AppEnvironment
    ) async {}

    func consumeOrCreateMessagingService(
        databaseWriter: any DatabaseWriter,
        databaseReader: any DatabaseReader,
        environment: AppEnvironment
    ) async -> (service: any MessagingServiceProtocol, conversationId: String?) {
        let clientId = "unused-client-\(nextInboxNumber)"
        let conversationId = currentUnusedConversationId
        currentUnusedInboxId = nil
        currentUnusedConversationId = nil
        nextInboxNumber += 1
        let mockStateManager = MockInboxStateManager(initialState: .idle(clientId: clientId))
        return (service: MockMessagingService(inboxStateManager: mockStateManager), conversationId: conversationId)
    }

    func consumeInboxOnly(
        databaseWriter: any DatabaseWriter,
        databaseReader: any DatabaseReader,
        environment: AppEnvironment
    ) async -> any MessagingServiceProtocol {
        let clientId = "unused-client-\(nextInboxNumber)"
        currentUnusedInboxId = nil
        currentUnusedConversationId = nil
        nextInboxNumber += 1
        let mockStateManager = MockInboxStateManager(initialState: .idle(clientId: clientId))
        return MockMessagingService(inboxStateManager: mockStateManager)
    }

    func clearUnusedFromKeychain() {}

    func isUnusedConversation(_ conversationId: String) -> Bool {
        return conversationId == currentUnusedConversationId
    }

    func isUnusedInbox(_ inboxId: String) -> Bool {
        return inboxId == currentUnusedInboxId
    }

    func hasUnusedConversation() -> Bool {
        return currentUnusedConversationId != nil
    }

    /// Test helper: simulate background creation of new unused conversation
    func markNewInboxAvailable() {
        currentUnusedInboxId = "unused-inbox-\(nextInboxNumber)"
        currentUnusedConversationId = "unused-conversation-\(nextInboxNumber)"
    }
}

// MARK: - DelayingMockUnusedConversationCache
//
// Lifted from the same legacy file. Used by tests that want to
// simulate race conditions during consumption.

actor DelayingMockUnusedConversationCache: UnusedConversationCacheProtocol {
    private var consumeStartedContinuation: CheckedContinuation<Void, Never>?
    private var resumeContinuation: CheckedContinuation<Void, Never>?
    private var hasConsumed: Bool = false
    private var consumeStarted: Bool = false

    func prepareUnusedConversationIfNeeded(
        databaseWriter: any DatabaseWriter,
        databaseReader: any DatabaseReader,
        environment: AppEnvironment
    ) async {}

    func consumeOrCreateMessagingService(
        databaseWriter: any DatabaseWriter,
        databaseReader: any DatabaseReader,
        environment: AppEnvironment
    ) async -> (service: any MessagingServiceProtocol, conversationId: String?) {
        consumeStarted = true
        consumeStartedContinuation?.resume()
        consumeStartedContinuation = nil

        await withCheckedContinuation { continuation in
            resumeContinuation = continuation
        }

        hasConsumed = true
        return (service: MockMessagingService(), conversationId: nil)
    }

    func consumeInboxOnly(
        databaseWriter: any DatabaseWriter,
        databaseReader: any DatabaseReader,
        environment: AppEnvironment
    ) async -> any MessagingServiceProtocol {
        hasConsumed = true
        return MockMessagingService()
    }

    func clearUnusedFromKeychain() {}

    func isUnusedConversation(_ conversationId: String) -> Bool {
        return false
    }

    func isUnusedInbox(_ inboxId: String) -> Bool {
        return false
    }

    func hasUnusedConversation() -> Bool {
        return !hasConsumed
    }

    /// Test helper: wait for `consumeOrCreateMessagingService` to start
    func waitForConsumeStart() async {
        await withCheckedContinuation { continuation in
            consumeStartedContinuation = continuation
        }
    }

    /// Test helper: resume the in-flight consume operation
    func resumeConsume() {
        resumeContinuation?.resume()
        resumeContinuation = nil
    }
}

// MARK: - SimpleMockUnusedConversationCache
//
// Stage 6f: lifted from
// `ConvosCore/Tests/ConvosCoreTests/InboxLifecycleManagerTests.swift`.
// Minimal mock that always hands out a fresh `MockMessagingService`
// without tracking any cached state.

actor SimpleMockUnusedConversationCache: UnusedConversationCacheProtocol {
    func prepareUnusedConversationIfNeeded(
        databaseWriter: any DatabaseWriter,
        databaseReader: any DatabaseReader,
        environment: AppEnvironment
    ) async {}

    func consumeOrCreateMessagingService(
        databaseWriter: any DatabaseWriter,
        databaseReader: any DatabaseReader,
        environment: AppEnvironment
    ) async -> (service: any MessagingServiceProtocol, conversationId: String?) {
        (service: MockMessagingService(), conversationId: nil)
    }

    func consumeInboxOnly(
        databaseWriter: any DatabaseWriter,
        databaseReader: any DatabaseReader,
        environment: AppEnvironment
    ) async -> any MessagingServiceProtocol {
        MockMessagingService()
    }

    func clearUnusedFromKeychain() {}

    func isUnusedConversation(_ conversationId: String) -> Bool { false }

    func isUnusedInbox(_ inboxId: String) -> Bool { false }

    func hasUnusedConversation() -> Bool { false }
}

// MARK: - InboxLifecycleManager test helpers
//
// Stage 6f: helper extensions lifted from the legacy
// `InboxLifecycleManagerTests.swift` so the migrated tests don't
// have to repeat the wake-and-discard / sleep boilerplate.

extension InboxLifecycleManager {
    /// Helper for tests to wake without returning the non-Sendable service
    func wakeAndDiscard(clientId: String, inboxId: String, reason: WakeReason) async throws {
        _ = try await wake(clientId: clientId, inboxId: inboxId, reason: reason)
    }

    /// Helper for tests to getOrWake without returning the non-Sendable service
    func getOrWakeAndDiscard(clientId: String, inboxId: String) async throws {
        _ = try await getOrWake(clientId: clientId, inboxId: inboxId)
    }

    /// Test helper to manually mark a client as sleeping
    func setSleepingForTest(clientId: String) async {
        if isAwake(clientId: clientId) {
            await sleep(clientId: clientId)
        }
    }
}
