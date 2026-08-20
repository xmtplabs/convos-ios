import ConvosComposer
import ConvosCore
import XCTest
@testable import Convos

@MainActor
final class AgentChatPrototypeStateTests: XCTestCase {
    func testGroupAgentStaysFirstWhenPersonalAgentsAreConnected() {
        let lanes = AgentChatLane.available(
            live: [],
            connectedExternalProviders: [.town, .tasklet]
        )

        XCTAssertEqual(lanes.map(\.name), ["Space Abilities", "Town", "Tasklet", "Ghost Mode"])
        guard let firstLane = lanes.first,
              case .prototype(.spaceAbilities) = firstLane.kind else {
            return XCTFail("The orange group agent must remain the first/default lane")
        }
    }

    func testDraftsStayWithTheirAgentLane() {
        let state = AgentChatPrototypeState(restoresConnectedExternalProviders: false)
        let flightTracker = AgentChatLane.prototype(.flightTracker)
        let shanesAgent = AgentChatLane.prototype(.shanesAgent)

        state.draftBinding(for: flightTracker).wrappedValue = "Track UA 405"
        state.draftBinding(for: shanesAgent).wrappedValue = "Plan tomorrow"

        XCTAssertEqual(state.draftBinding(for: flightTracker).wrappedValue, "Track UA 405")
        XCTAssertEqual(state.draftBinding(for: shanesAgent).wrappedValue, "Plan tomorrow")
    }

    func testAgentWorkContinuesAfterSwitchingLanes() async throws {
        let state = AgentChatPrototypeState(restoresConnectedExternalProviders: false)
        let flightTracker = AgentChatLane.prototype(.flightTracker)
        let shanesAgent = AgentChatLane.prototype(.shanesAgent)

        state.select(flightTracker)
        state.draftBinding(for: flightTracker).wrappedValue = "Track UA 405"
        state.send(in: flightTracker)
        state.select(shanesAgent)

        XCTAssertTrue(state.isWorking(flightTracker))
        XCTAssertEqual(state.selectedLaneId, shanesAgent.id)

        try await Task.sleep(for: .milliseconds(950))

        XCTAssertFalse(state.isWorking(flightTracker))
        XCTAssertEqual(state.messages(for: flightTracker).last?.sender, .agent)
        XCTAssertEqual(state.selectedLaneId, shanesAgent.id)
    }

    func testMessageHandoffQueuesWithoutTakingOverTheAgentDraft() {
        let state = AgentChatPrototypeState(restoresConnectedExternalProviders: false)
        let lane = AgentChatLane.ghost
        state.draftBinding(for: lane).wrappedValue = "Keep my unfinished thought"

        let wasQueued = state.send(text: "Priya shared in this Convo:\nShip the prototype", in: lane)

        XCTAssertTrue(wasQueued)
        XCTAssertEqual(state.draftBinding(for: lane).wrappedValue, "Keep my unfinished thought")
        XCTAssertEqual(state.messages(for: lane).last?.sender, .user)
        XCTAssertEqual(state.messages(for: lane).last?.text, "Priya shared in this Convo:\nShip the prototype")
    }

    func testForwardedAgentTranscriptRestoresFromDeviceKeychain() {
        let keychain = AgentTranscriptMemoryKeychain()
        let lane = AgentChatLane.ghost
        let firstState = AgentChatPrototypeState(
            restoresConnectedExternalProviders: false,
            transcriptKeychain: keychain
        )
        firstState.bind(to: "convo-123")
        XCTAssertTrue(firstState.send(text: "Keep this Grokbot handoff", in: lane))

        let restoredState = AgentChatPrototypeState(
            restoresConnectedExternalProviders: false,
            transcriptKeychain: keychain
        )
        restoredState.bind(to: "convo-123")

        XCTAssertEqual(restoredState.messages(for: lane).last?.text, "Keep this Grokbot handoff")
        XCTAssertEqual(restoredState.messages(for: lane).last?.sender, .user)
    }

    func testAgentReceiptTracksPrivateDeliveryStatus() {
        let store = MessageAgentReceiptStore()
        let receipt = AgentChatLane.external(.tasklet).receipt(
            conversationId: "convo-123",
            messageId: "message-456"
        )

        store.upsert(receipt)
        store.updateStatus(.sent, receiptId: receipt.id)

        let storedReceipt = store.receipts(
            conversationId: "convo-123",
            messageId: "message-456"
        ).first
        XCTAssertEqual(storedReceipt?.agentName, "Tasklet")
        XCTAssertEqual(storedReceipt?.status, .sent)
    }

    func testGhostShareCopiesOnlyTheSelectedMessage() {
        let state = AgentChatPrototypeState(restoresConnectedExternalProviders: false)
        let destination = AgentChatLane.prototype(.spaceAbilities)
        let destinationMessageCount = state.messages(for: destination).count
        let selectedMessage = AgentChatPrototypeMessage(sender: .agent, text: "Share this exact result")
        state.share(selectedMessage, to: destination)

        let destinationMessages = state.messages(for: destination)
        XCTAssertEqual(destinationMessages.count, destinationMessageCount + 1)
        XCTAssertEqual(destinationMessages.last?.text, "Shared from Ghost Mode:\n\(selectedMessage.text)")
        XCTAssertEqual(state.shareConfirmation, "Shared only this message with Space Abilities")
    }

    func testGhostShareDoesNotClaimARealAgentReceivedPrototypeContent() {
        let state = AgentChatPrototypeState(restoresConnectedExternalProviders: false)
        let message = AgentChatPrototypeMessage(sender: .agent, text: "Private result")
        let liveAgent = AgentChatLane(
            id: "live:space",
            name: "Space Abilities",
            subtitle: "Available in this convo",
            kind: .live(inboxId: "space"),
            profile: nil,
            agentVerification: .unverified
        )

        state.share(message, to: liveAgent)

        XCTAssertEqual(
            state.shareConfirmation,
            "Prototype preview only — nothing was sent to Space Abilities"
        )
        XCTAssertTrue(state.messages(for: liveAgent).isEmpty)
    }

    func testExternalAgentConnectionIsDeduplicatedAndKeepsPrivateDefaults() {
        let state = AgentChatPrototypeState(restoresConnectedExternalProviders: false)

        state.connect(.codex)
        state.connect(.codex)

        XCTAssertEqual(state.connectedExternalProviders, [.codex])
        XCTAssertEqual(state.access(for: .codex), .privateDesktop)
    }

    func testExternalAgentAccessStaysScopedToProvider() {
        let state = AgentChatPrototypeState(restoresConnectedExternalProviders: false)
        state.connect(.codex)
        state.connect(.openClaw)

        state.accessBinding(for: .openClaw).wrappedValue = ExternalAgentAccess(
            desktopReadWrite: true,
            groupListenAndReply: true,
            scopedMemberDMs: true
        )

        XCTAssertEqual(state.access(for: .codex), .privateDesktop)
        XCTAssertTrue(state.access(for: .openClaw).groupListenAndReply)
        XCTAssertTrue(state.access(for: .openClaw).scopedMemberDMs)
    }

    func testExternalAgentUsesItsOwnLaneState() {
        let state = AgentChatPrototypeState(restoresConnectedExternalProviders: false)
        let codex = AgentChatLane.external(.codex)
        let claude = AgentChatLane.external(.claudeCode)

        state.draftBinding(for: codex).wrappedValue = "Edit the Home card"
        state.draftBinding(for: claude).wrappedValue = "Review the draft"

        XCTAssertEqual(state.draftBinding(for: codex).wrappedValue, "Edit the Home card")
        XCTAssertEqual(state.draftBinding(for: claude).wrappedValue, "Review the draft")
        XCTAssertNotEqual(state.messages(for: codex).first?.text, state.messages(for: claude).first?.text)
    }

    func testGrokBotIsLiveAndCanBeConnected() {
        let provider = ExternalAgentProvider.grokBot
        let state = AgentChatPrototypeState(restoresConnectedExternalProviders: false)

        XCTAssertEqual(provider.displayName, "Grok Bot")
        XCTAssertTrue(provider.shortDescription.contains("Multiple"))
        XCTAssertEqual(provider.connectionAvailability, .live)

        state.connect(provider)

        XCTAssertTrue(state.connectedExternalProviders.contains(provider))
    }

    func testConnectMCPIsComingSoonAndCannotBeConnected() {
        let provider = ExternalAgentProvider.connectMCP
        let state = AgentChatPrototypeState(restoresConnectedExternalProviders: false)

        XCTAssertEqual(provider.displayName, "Connect MCP")
        XCTAssertEqual(provider.connectionAvailability, .comingSoon)

        state.connect(provider)

        XCTAssertFalse(state.connectedExternalProviders.contains(provider))
    }

    func testPersonalContextApprovalSharesOnlyTheSuggestedItems() {
        let state = AgentChatPrototypeState(restoresConnectedExternalProviders: false)
        let bundle = PersonalContextBundle.suggestedForCurrentConvo

        state.approvePersonalContext(bundle)
        state.approvePersonalContext(bundle)

        XCTAssertEqual(
            state.approvedPersonalContextItemIds,
            Set(bundle.items.map(\.id))
        )
        XCTAssertTrue(state.hasApprovedPersonalContext)
    }

    func testRemovingPersonalContextRevokesTheWholeGroupGrant() {
        let state = AgentChatPrototypeState(restoresConnectedExternalProviders: false)
        state.approvePersonalContext(.suggestedForCurrentConvo)

        state.removePersonalContextAccess()

        XCTAssertTrue(state.approvedPersonalContextItemIds.isEmpty)
        XCTAssertFalse(state.hasApprovedPersonalContext)
    }

    func testPersonalContextRestoreDoesNotCreateAnotherAgentLane() {
        let state = AgentChatPrototypeState(restoresConnectedExternalProviders: false)
        let itemIds = Set(PersonalContextBundle.suggestedForCurrentConvo.items.prefix(2).map(\.id))

        state.restorePersonalContext(itemIds: itemIds)

        XCTAssertEqual(state.approvedPersonalContextItemIds, itemIds)
        XCTAssertNil(state.selectedLaneId)
        XCTAssertTrue(state.messagesByLane.isEmpty)
    }

    func testContextLibrarySuggestsAUsefulSubsetWithoutHidingTheCatalog() {
        let suggestedIds = Set(PersonalContextBundle.suggestedForCurrentConvo.items.map(\.id))
        let catalogIds = Set(PersonalContextBundle.catalog.map(\.id))

        XCTAssertEqual(suggestedIds.count, 4)
        XCTAssertEqual(catalogIds.count, 8)
        XCTAssertTrue(suggestedIds.isSubset(of: catalogIds))
        XCTAssertEqual(Set(PersonalContextBundle.catalog.map(\.kind)), Set(PersonalContextItem.Kind.allCases))
    }

    func testContextShareReceiptBindsExactItemsToOneDestination() {
        let items = Array(PersonalContextBundle.catalog.prefix(2))
        let receipt = PersonalContextShareReceipt(destination: .members, items: items)

        XCTAssertEqual(receipt.destination, .members)
        XCTAssertEqual(receipt.items, items)
        XCTAssertTrue(receipt.id.hasPrefix("members:"))
    }

    func testShareContextIsHostOptInRatherThanAStandardAttachment() {
        XCTAssertFalse(ComposerAttachmentAction.standard.contains(.shareContext))
    }
}

private final class AgentTranscriptMemoryKeychain: KeychainServiceProtocol, @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String: Data] = [:]

    func saveString(_ value: String, account: String) throws {
        try saveData(Data(value.utf8), account: account)
    }

    func saveData(_ data: Data, account: String) throws {
        lock.withLock { values[account] = data }
    }

    func retrieveString(account: String) throws -> String? {
        try retrieveData(account: account).flatMap { String(data: $0, encoding: .utf8) }
    }

    func retrieveData(account: String) throws -> Data? {
        lock.withLock { values[account] }
    }

    func delete(account: String) throws {
        _ = lock.withLock { values.removeValue(forKey: account) }
    }
}
