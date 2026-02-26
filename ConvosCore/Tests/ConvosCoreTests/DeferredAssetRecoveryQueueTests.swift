@testable import ConvosCore
import Foundation
import Testing

@Suite("DeferredAssetRecoveryQueue Tests")
struct DeferredAssetRecoveryQueueTests {
    @Test("Enqueue deduplicates by asset URL")
    func testEnqueueDeduplicatesByURL() async {
        let queue = DeferredAssetRecoveryQueue()

        let first = RenewableAsset.profileAvatar(
            url: "https://example.com/a.bin",
            conversationId: "convo-1",
            inboxId: "inbox-1",
            lastRenewed: nil
        )
        let second = RenewableAsset.profileAvatar(
            url: "https://example.com/a.bin",
            conversationId: "convo-2",
            inboxId: "inbox-2",
            lastRenewed: nil
        )

        await queue.enqueue(first)
        await queue.enqueue(second)

        #expect(await queue.count == 1)
    }

    @Test("Drain returns queued assets and clears queue")
    func testDrainClearsQueue() async {
        let queue = DeferredAssetRecoveryQueue()

        let avatar = RenewableAsset.profileAvatar(
            url: "https://example.com/a.bin",
            conversationId: "convo-1",
            inboxId: "inbox-1",
            lastRenewed: nil
        )
        let groupImage = RenewableAsset.groupImage(
            url: "https://example.com/g.bin",
            conversationId: "convo-1",
            lastRenewed: nil
        )

        await queue.enqueue(avatar)
        await queue.enqueue(groupImage)

        let drained = await queue.drain()

        #expect(drained.count == 2)
        #expect(await queue.count == 0)
    }
}
