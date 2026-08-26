@testable import Convos
import ConvosCore
import Foundation
import Testing

struct DocItemReconcilerTests {
    @Test func compatibilityDetectorWarnsOnlyForNormalAgentRepliesWithoutDocEvents() {
        var detector = DocAgentCompatibilityDetector()

        detector.observe(text: "A normal assistant reply", isAgent: false)
        #expect(!detector.shouldWarn)

        detector.observe(text: "A normal assistant reply", isAgent: true)
        #expect(detector.shouldWarn)

        detector.observe(text: "⟦doc⟧not-even-valid-json", isAgent: true)
        #expect(!detector.shouldWarn)
    }

    @Test func compatibilityDetectorIgnoresHiddenClientProtocolMessages() {
        var detector = DocAgentCompatibilityDetector()

        detector.observe(text: #"⟦ans⟧{"id":"question","choice":"Dec 14"}"#, isAgent: true)
        detector.observe(text: #"⟦req⟧{"t":"doc-content","docId":"trip"}"#, isAgent: true)

        #expect(!detector.shouldWarn)
    }

    @MainActor
    @Test func resetClearsOnlyDocShellState() throws {
        let suiteName = "DocAgentResetTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let session = MockInboxesService()
        let docKeys = ["originConversationId", "welcome", "googleConnectHandled", "snapshot", "state"]
            .map { DocExperienceViewModel.storageKey($0, session: session) }
        docKeys.forEach { defaults.set("stored", forKey: $0) }
        defaults.set("keep", forKey: "unrelated")

        DocExperienceViewModel.resetAgentBinding(session: session, defaults: defaults)

        #expect(docKeys.allSatisfy { defaults.object(forKey: $0) == nil })
        #expect(defaults.string(forKey: "unrelated") == "keep")
    }

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
