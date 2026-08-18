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

    func testExternalAgentConnectionIsDeduplicatedAndKeepsHandoffDefaults() {
        let state = AgentChatPrototypeState()

        state.connect(.codex)
        state.connect(.codex)

        XCTAssertEqual(state.connectedExternalProviders, [.codex])
        XCTAssertEqual(state.handoff(for: .codex), .standard)
    }

    func testExternalAgentContextWindowStaysScopedToProvider() {
        let state = AgentChatPrototypeState()
        state.connect(.codex)
        state.connect(.openClaw)

        state.setHandoff(
            ExternalAgentHandoffConfiguration(
                contextWindow: .sevenDays,
                includesGroupDesktop: false
            ),
            for: .openClaw
        )

        XCTAssertEqual(state.handoff(for: .codex), .standard)
        XCTAssertEqual(state.handoff(for: .openClaw).contextWindow, .sevenDays)
        XCTAssertFalse(state.handoff(for: .openClaw).includesGroupDesktop)
    }

    func testExternalAgentPayloadNamesScopeAndPrivacyBoundary() {
        let payload = ExternalAgentProvider.grokBot.contextPayload(
            configuration: .standard
        )

        XCTAssertTrue(payload.contains("Last 24 hours"))
        XCTAssertTrue(payload.contains("group desktop information"))
        XCTAssertTrue(payload.contains("Ghost Mode"))
        XCTAssertTrue(payload.contains("does not export real conversation content"))
        XCTAssertTrue(AgentChatLane.external(.grokBot).subtitle.contains("Opens GrokBot"))
        XCTAssertEqual(ExternalAgentProvider.grokBot.launchURL.host, "grok.com")
        XCTAssertTrue(ExternalAgentProvider.grokBot.connectorKey.contains("DEMO"))
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
