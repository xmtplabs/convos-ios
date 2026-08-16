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
}
