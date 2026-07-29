@testable import ConvosCore
import Foundation
import Testing

/// Coverage for the owner-computed per-agent power signal (CON-807).
///
/// The backend computes `agentPowerDepleted` from the agent OWNER's wallet and
/// serves it per agent on `GET /v2/conversations/:id/participation`
/// (`agents[].agentPowerDepleted`) and `GET /v2/agents/join/:instanceId`. The
/// client binds every "lost power" surface to that field alone — the viewer's
/// own wallet is never an input. These tests pin the decode tolerance (the
/// field is additive; old backends omit it) and the display decision.
@Suite("Agent power signal")
struct AgentPowerSignalTests {
    private func member(inboxId: String, isAgent: Bool, isCurrentUser: Bool = false) -> ConversationMember {
        ConversationMember(
            profile: Profile(
                inboxId: inboxId,
                conversationId: "convo-1",
                name: inboxId,
                avatar: nil
            ),
            role: .member,
            isCurrentUser: isCurrentUser,
            isAgent: isAgent
        )
    }

    // MARK: - Decode tolerance (additive field, old backends)

    @Test("Legacy participation payload (no agents array) decodes; map is nil = unknown")
    func legacyParticipationPayloadDecodes() throws {
        let json = Data(#"{"success":true,"conversationId":"c1","mode":"speak"}"#.utf8)
        let response = try JSONDecoder().decode(ConvosAPI.AgentParticipationResponse.self, from: json)
        #expect(response.success)
        #expect(response.mode == "speak")
        #expect(response.agents == nil)
        // nil (unknown), NOT an empty "everyone healthy" map — callers keep
        // their last state instead of clearing.
        #expect(response.agentPowerDepletedByInboxId == nil)
    }

    @Test("Participation payload with agents builds the inboxId map; flagless entries stay unknown")
    func participationPayloadBuildsMap() throws {
        let json = Data("""
        {"success":true,"conversationId":"c1","mode":"speak","agents":[
            {"inboxId":"agent-a","agentPowerDepleted":true},
            {"inboxId":"agent-b","agentPowerDepleted":false},
            {"inboxId":"agent-c"}
        ]}
        """.utf8)
        let response = try JSONDecoder().decode(ConvosAPI.AgentParticipationResponse.self, from: json)
        #expect(response.agents?.count == 3)
        #expect(response.agentPowerDepletedByInboxId == ["agent-a": true, "agent-b": false])
    }

    @Test("Join-status payload decodes with and without agentPowerDepleted")
    func joinStatusPayloadDecodes() throws {
        let legacy = Data(#"{"success":true,"instanceId":"i1","joinStatus":"joined","joined":true}"#.utf8)
        let legacyResponse = try JSONDecoder().decode(ConvosAPI.AgentJoinStatusResponse.self, from: legacy)
        #expect(legacyResponse.agentPowerDepleted == nil)

        let enriched = Data(#"{"success":true,"instanceId":"i1","joinStatus":"joined","joined":true,"agentPowerDepleted":true}"#.utf8)
        let enrichedResponse = try JSONDecoder().decode(ConvosAPI.AgentJoinStatusResponse.self, from: enriched)
        #expect(enrichedResponse.agentPowerDepleted == true)
    }

    // MARK: - Display decision

    /// The CON-807 regression: a viewer at 0 credits looks at someone else's
    /// FUNDED agent. The viewer's own wallet says depleted, but the wallet is
    /// not an input — the owner-computed signal says false, so no indicator.
    @Test("Zero-balance viewer sees a funded owner's agent as working")
    func zeroBalanceViewerSeesFundedAgentAsWorking() {
        let viewerBalance = CreditBalance(
            balance: 0,
            monthlyGrant: 500_000,
            monthlyGrantUsed: 500_000,
            nextRefreshAt: Date(),
            periodLabel: "July"
        )
        #expect(viewerBalance.isDepleted) // Quarter's wallet state...

        let members = [
            member(inboxId: "viewer", isAgent: false, isCurrentUser: true),
            member(inboxId: "carolines-agent", isAgent: true),
        ]
        // ...and the backend's owner-computed answer for Caroline's agent.
        let depleted = members.agentsWithDepletedPower(["carolines-agent": false])
        #expect(depleted.isEmpty)
    }

    @Test("Absent signal (old backend / unregistered agent) shows nothing")
    func absentSignalShowsNothing() {
        let members = [
            member(inboxId: "viewer", isAgent: false, isCurrentUser: true),
            member(inboxId: "agent-a", isAgent: true),
        ]
        #expect(members.agentsWithDepletedPower([:]).isEmpty)
        #expect(members.agentsWithDepletedPower(["other-agent": true]).isEmpty)
    }

    @Test("Depleted owner flags exactly that agent, for any viewer")
    func depletedOwnerFlagsAgent() {
        let members = [
            member(inboxId: "viewer", isAgent: false, isCurrentUser: true),
            member(inboxId: "agent-a", isAgent: true),
            member(inboxId: "agent-b", isAgent: true),
        ]
        let map = ["agent-a": true, "agent-b": false, "viewer": true]
        let depleted = members.agentsWithDepletedPower(map)
        #expect(depleted.map(\.profile.inboxId) == ["agent-a"])
        // A non-agent member can never be flagged, whatever the map says.
        #expect(!depleted.contains(where: { !$0.isAgent }))
    }
}
