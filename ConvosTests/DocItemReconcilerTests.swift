@testable import Convos
import ConvosCore
import Foundation
import Testing

struct DocItemReconcilerTests {
    @Test func compatibilityDetectorIgnoresSetupProseUntilAgentRepliesToSourceMaterial() {
        var detector = DocAgentCompatibilityDetector()

        detector.observe(
            text: "An older group message.",
            sender: .currentUser,
            position: position(0)
        )
        detector.observe(
            text: "Google Docs access is approved.",
            sender: .agent,
            position: position(1)
        )
        #expect(!detector.shouldWarn)

        detector.observe(
            text: "Plan a team offsite in October.",
            sender: .currentUser,
            position: position(2)
        )
        #expect(!detector.shouldWarn)

        detector.observe(
            text: "I can help plan that.",
            sender: .agent,
            position: position(3)
        )
        #expect(detector.shouldWarn)
    }

    @Test func compatibilityDetectorDoesNotTreatAnswersAsSourceMaterial() {
        var detector = DocAgentCompatibilityDetector()

        detector.observe(
            text: #"⟦ans⟧{"id":"question","choice":"Dec 14"}"#,
            sender: .currentUser,
            position: position(1)
        )
        detector.observe(
            text: "A normal assistant reply",
            sender: .agent,
            position: position(2)
        )

        #expect(!detector.shouldWarn)
    }

    @Test func compatibilityDetectorSentinelDisarmsWrongAgentWarning() {
        var detector = DocAgentCompatibilityDetector()

        detector.observe(text: "Hello, I'm your assistant.", sender: .agent, position: position(0))
        detector.observe(text: "Draft a launch plan.", sender: .currentUser, position: position(1))
        detector.observe(text: "Working on it.", sender: .agent, position: position(2))
        #expect(detector.shouldWarn)

        detector.observe(text: "⟦doc⟧not-even-valid-json", sender: .agent, position: position(3))
        #expect(!detector.shouldWarn)
    }

    @Test func startupTimeoutWaitsForColdProvisioningAndKeepsActiveWorkNonTerminal() {
        #expect(DocAgentStartupTimeoutPolicy.deadline == .seconds(90))
        #expect(!DocAgentStartupTimeoutPolicy.shouldFail(
            dmIsReady: false,
            provisioningOrRebindIsActive: true
        ))
        #expect(!DocAgentStartupTimeoutPolicy.shouldFail(
            dmIsReady: true,
            provisioningOrRebindIsActive: false
        ))
        #expect(DocAgentStartupTimeoutPolicy.shouldFail(
            dmIsReady: false,
            provisioningOrRebindIsActive: false
        ))
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

    private func position(_ seconds: TimeInterval) -> DocMessagePosition {
        DocMessagePosition(
            date: Date(timeIntervalSince1970: seconds),
            messageId: "message-\(seconds)"
        )
    }
}
