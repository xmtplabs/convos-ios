@testable import ConvosCore
import Foundation
import Testing
import XMTPiOS

/// Unit coverage for the ambient default-agent building blocks that carry
/// logic independent of the network/provision path (which is disabled under
/// tests): the coordinator's dedup/latch/idempotency bookkeeping and the
/// invisible `conversation_ready` codec.
@Suite("Default conversation agent")
struct DefaultConversationAgentTests {
    private actor Counter {
        private var count: Int = 0
        func increment() { count += 1 }
        func value() -> Int { count }
    }

    @Test("provisionTask shares one task per conversation until cleared")
    func provisionTaskDedupes() async {
        let coordinator = DefaultConversationAgentCoordinator()
        let counter = Counter()

        let first = await coordinator.provisionTask(for: "c1") { await counter.increment() }
        let second = await coordinator.provisionTask(for: "c1") { await counter.increment() }
        await first.value
        await second.value
        // The second call returns the in-flight task and drops its operation,
        // so only one provision ran.
        #expect(await counter.value() == 1)

        await coordinator.clearProvisionTask(for: "c1")
        let third = await coordinator.provisionTask(for: "c1") { await counter.increment() }
        await third.value
        // After a clear, a later ensure runs a fresh provision.
        #expect(await counter.value() == 2)
    }

    @Test("shouldSendReadySignal latches once per conversation")
    func readySignalLatchesOnce() async {
        let coordinator = DefaultConversationAgentCoordinator()
        #expect(await coordinator.shouldSendReadySignal(for: "c1") == true)
        #expect(await coordinator.shouldSendReadySignal(for: "c1") == false)
        // A different conversation still gets its one shot.
        #expect(await coordinator.shouldSendReadySignal(for: "c2") == true)
    }

    @Test("joinKey is stable per conversation and re-mints after clear")
    func joinKeyStableThenReminted() async {
        let coordinator = DefaultConversationAgentCoordinator()
        let first = await coordinator.joinKey(for: "c1")
        let second = await coordinator.joinKey(for: "c1")
        #expect(first == second)

        await coordinator.clearJoinKey(for: "c1")
        let third = await coordinator.joinKey(for: "c1")
        #expect(third != first)
    }

    @Test("conversation_ready codec round-trips and never pushes")
    func codecRoundTrips() throws {
        let codec = ConversationReadyCodec()
        #expect(codec.contentType.authorityID == "convos.org")
        #expect(codec.contentType.typeID == "conversation_ready")

        let encoded = try codec.encode(content: ConversationReadyContent(version: 1))
        let decoded = try codec.decode(content: encoded)
        #expect(decoded.version == 1)

        #expect(try codec.shouldPush(content: ConversationReadyContent()) == false)
        #expect(try codec.fallback(content: ConversationReadyContent()) == nil)
    }

    @Test("conversation_ready codec rejects empty content")
    func codecRejectsEmptyContent() {
        let codec = ConversationReadyCodec()
        let empty = EncodedContent()
        #expect(throws: ConversationReadyCodecError.self) {
            _ = try codec.decode(content: empty)
        }
    }
}
