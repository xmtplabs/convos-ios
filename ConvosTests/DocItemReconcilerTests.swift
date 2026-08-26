@testable import Convos
import ConvosCore
import Foundation
import Testing

struct DocItemReconcilerTests {
    @Test func resolvedTombstonePreventsColdHistoryFromRestoringItem() throws {
        let item = waitingItem(id: "cold-item")
        var pendingItems = [item]
        var resolvedIds: Set<String> = []

        #expect(DocItemReconciler.apply(
            .itemResolved(id: item.id),
            pendingItems: &pendingItems,
            resolvedItemIds: &resolvedIds
        ))
        #expect(pendingItems.isEmpty)

        #expect(!DocItemReconciler.apply(
            .item(item),
            pendingItems: &pendingItems,
            resolvedItemIds: &resolvedIds
        ))
        #expect(pendingItems.isEmpty)
        #expect(resolvedIds == [item.id])
    }

    @Test func newerItemPayloadReplacesExistingPendingItem() throws {
        let original = waitingItem(id: "question", headline: "Old question")
        let updated = waitingItem(id: "question", headline: "Current question")
        var pendingItems = [original]
        var resolvedIds: Set<String> = []

        #expect(DocItemReconciler.apply(
            .item(updated),
            pendingItems: &pendingItems,
            resolvedItemIds: &resolvedIds
        ))
        #expect(pendingItems == [updated])
    }

    private func waitingItem(
        id: String,
        headline: String = "Which date works?"
    ) -> DocWaitingItem {
        DocWaitingItem(
            id: id,
            kind: .question,
            headline: headline,
            context: "Pick a date.",
            createdAt: Date(timeIntervalSince1970: 1)
        )
    }
}
