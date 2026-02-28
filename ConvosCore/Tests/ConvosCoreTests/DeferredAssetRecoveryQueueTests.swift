@testable import ConvosCore
import Foundation
import Testing

@Suite("DeferredAssetRecoveryQueue Tests")
struct DeferredAssetRecoveryQueueTests {
    @Test("Enqueue deduplicates by asset URL with last-write wins")
    func testEnqueueDeduplicatesByURLLastWriteWins() async {
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

        let batch = await queue.nextBatchForProcessing()
        #expect(batch?.count == 1)
        if case let .profileAvatar(_, conversationId, inboxId, _) = batch?.first?.asset {
            #expect(conversationId == "convo-2")
            #expect(inboxId == "inbox-2")
        } else {
            Issue.record("Expected profile avatar entry")
        }

        await queue.finishProcessing(requeue: [])
    }

    @Test("Processing batch drains queue and finish resets processing lock")
    func testBatchProcessingLifecycle() async {
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

        let firstBatch = await queue.nextBatchForProcessing()
        #expect(firstBatch?.count == 2)
        #expect(await queue.count == 0)

        let secondBatch = await queue.nextBatchForProcessing()
        #expect(secondBatch == nil)

        await queue.finishProcessing(requeue: [])

        await queue.enqueue(avatar)
        let thirdBatch = await queue.nextBatchForProcessing()
        #expect(thirdBatch?.count == 1)
        await queue.finishProcessing(requeue: [])
    }
}
