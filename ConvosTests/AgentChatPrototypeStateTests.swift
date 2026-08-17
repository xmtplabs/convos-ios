import XCTest
@testable import Convos

@MainActor
final class AgentChatPrototypeStateTests: XCTestCase {
    func testDraftsStayWithTheirAgentLane() {
        let state = AgentChatPrototypeState()
        let flightTracker = AgentChatLane.prototype(.flightTracker)
        let shanesAgent = AgentChatLane.prototype(.shanesAgent)

        state.draftBinding(for: flightTracker).wrappedValue = "Track UA 405"
        state.draftBinding(for: shanesAgent).wrappedValue = "Plan tomorrow"

        XCTAssertEqual(state.draftBinding(for: flightTracker).wrappedValue, "Track UA 405")
        XCTAssertEqual(state.draftBinding(for: shanesAgent).wrappedValue, "Plan tomorrow")
    }

    func testAgentWorkContinuesAfterSwitchingLanes() async throws {
        let state = AgentChatPrototypeState()
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

    func testGhostShareCopiesOnlyTheSelectedMessage() {
        let state = AgentChatPrototypeState()
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
        let state = AgentChatPrototypeState()
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
        let state = AgentChatPrototypeState()

        state.connect(.codex)
        state.connect(.codex)

        XCTAssertEqual(state.connectedExternalProviders, [.codex])
        XCTAssertEqual(state.access(for: .codex), .privateDesktop)
    }

    func testExternalAgentAccessStaysScopedToProvider() {
        let state = AgentChatPrototypeState()
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
        let state = AgentChatPrototypeState()
        let codex = AgentChatLane.external(.codex)
        let claude = AgentChatLane.external(.claudeCode)

        state.draftBinding(for: codex).wrappedValue = "Edit the Home card"
        state.draftBinding(for: claude).wrappedValue = "Review the draft"

        XCTAssertEqual(state.draftBinding(for: codex).wrappedValue, "Edit the Home card")
        XCTAssertEqual(state.draftBinding(for: claude).wrappedValue, "Review the draft")
        XCTAssertNotEqual(state.messages(for: codex).first?.text, state.messages(for: claude).first?.text)
    }

    func testCrossConvoLinkIsDeduplicatedAndSharesFullAgentLayer() {
        let state = AgentChatPrototypeState()
        let link = ConvoAgentMemoryLink.allCapabilities(for: .flightTracker)

        state.link(.flightTracker, configuration: link)
        state.link(.flightTracker, configuration: link)

        XCTAssertEqual(state.linkedConvoAgents, [.flightTracker])
        XCTAssertEqual(state.memoryLink(for: .flightTracker), link)
        XCTAssertEqual(
            link.sharedCapabilityIds,
            Set(ConvoOwnedAgent.flightTracker.portableCapabilities.map(\.id))
        )
    }

    func testDisconnectRemovesOnlyTheSelectedCrossConvoAgent() {
        let state = AgentChatPrototypeState()
        state.link(.flightTracker, configuration: .allCapabilities(for: .flightTracker))
        state.link(.hotelScout, configuration: .allCapabilities(for: .hotelScout))

        state.unlink(.flightTracker)

        XCTAssertEqual(state.linkedConvoAgents, [.hotelScout])
        XCTAssertEqual(
            state.memoryLink(for: .hotelScout),
            .allCapabilities(for: .hotelScout)
        )
    }

    func testCrossConvoAgentUsesItsOwnLaneState() {
        let state = AgentChatPrototypeState()
        let sharedFlightAgent = AgentChatLane.linkedConvo(.flightTracker)
        let localFlightAgent = AgentChatLane.prototype(.flightTracker)

        state.draftBinding(for: sharedFlightAgent).wrappedValue = "Track the shared flight"

        XCTAssertEqual(state.draftBinding(for: sharedFlightAgent).wrappedValue, "Track the shared flight")
        XCTAssertTrue(state.draftBinding(for: localFlightAgent).wrappedValue.isEmpty)
        XCTAssertTrue(state.messages(for: sharedFlightAgent).first?.text.contains("now shared") == true)
    }
}
