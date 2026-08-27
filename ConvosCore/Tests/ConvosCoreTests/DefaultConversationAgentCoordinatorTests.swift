@testable import ConvosCore
import Foundation
import Testing

/// The bookkeeping behind "every conversation gets a silent default agent":
/// concurrent ensures share one provision, a failed one is forgettable so a
/// later ensure retries, and the UI can ask whether a provision is already
/// under way (so the Agent tab waits on it instead of offering to add another
/// agent).
@Suite("Default Conversation Agent Coordinator Tests")
struct DefaultConversationAgentCoordinatorTests {
    @Test("Concurrent ensures for one conversation share a single provision")
    func concurrentEnsuresShareOneProvision() async {
        let coordinator = DefaultConversationAgentCoordinator()
        let counter = ProvisionCounter()

        let first = await coordinator.provisionTask(for: "conv-1") { await counter.increment() }
        let second = await coordinator.provisionTask(for: "conv-1") { await counter.increment() }
        await first.value
        await second.value

        #expect(await counter.count == 1)
    }

    @Test("Separate conversations provision separately")
    func separateConversationsProvisionSeparately() async {
        let coordinator = DefaultConversationAgentCoordinator()
        let counter = ProvisionCounter()

        await coordinator.provisionTask(for: "conv-1") { await counter.increment() }.value
        await coordinator.provisionTask(for: "conv-2") { await counter.increment() }.value

        #expect(await counter.count == 2)
    }

    @Test("A conversation with a provision under way reports itself as provisioning")
    func provisioningIsVisibleToCallers() async {
        let coordinator = DefaultConversationAgentCoordinator()

        #expect(await coordinator.isProvisioning("conv-1") == false)
        await coordinator.provisionTask(for: "conv-1") {}.value
        #expect(await coordinator.isProvisioning("conv-1") == true,
                "The Agent tab reads this to wait on the silent join instead of offering another agent")
        #expect(await coordinator.isProvisioning("conv-2") == false)
    }

    @Test("A forgotten provision is retryable and no longer reports as provisioning")
    func clearedProvisionIsRetryable() async {
        let coordinator = DefaultConversationAgentCoordinator()
        let counter = ProvisionCounter()

        await coordinator.provisionTask(for: "conv-1") { await counter.increment() }.value
        await coordinator.clearProvisionTask(for: "conv-1")

        #expect(await coordinator.isProvisioning("conv-1") == false)
        await coordinator.provisionTask(for: "conv-1") { await counter.increment() }.value
        #expect(await counter.count == 2)
    }

    @Test("The join key is stable across retries and relaunches, then re-minted after it is cleared")
    func joinKeyIsStableUntilCleared() async throws {
        let suiteName = "DefaultConversationAgentCoordinatorTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let coordinator = DefaultConversationAgentCoordinator(defaultsSuiteName: suiteName)

        let first = await coordinator.joinKey(for: "conv-1")
        let second = await coordinator.joinKey(for: "conv-1")
        #expect(first == second, "Retries reuse the key so the backend adopts the in-flight instance")

        let relaunched = DefaultConversationAgentCoordinator(defaultsSuiteName: suiteName)
        let restored = await relaunched.joinKey(for: "conv-1")
        #expect(restored == first)

        await relaunched.clearJoinKey(for: "conv-1")
        let restarted = DefaultConversationAgentCoordinator(defaultsSuiteName: suiteName)
        let third = await restarted.joinKey(for: "conv-1")
        #expect(third != first)
    }
}

private actor ProvisionCounter {
    private(set) var count: Int = 0

    func increment() {
        count += 1
    }
}
