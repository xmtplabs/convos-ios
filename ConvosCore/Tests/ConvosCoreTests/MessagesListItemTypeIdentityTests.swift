@testable import ConvosCore
import Foundation
import Testing

// MARK: - Agent DM Header Identity

/// The agent-DM header's identity carries the variant slug so a stamp that
/// lands after first render - the profile sync that fills in the agent
/// member - changes the item's id and forces the diffable data source to
/// rebuild the cell. Were the id constant, the header would keep rendering
/// its pre-sync self and the variant badge would never appear.
struct MessagesListItemTypeAgentDmInfoIdentityTests {
    private static let stamp: AgentVariantStamp = .init(
        slug: "pr-3454",
        label: "G Maps",
        whatToTest: "Places lookups run through the Maps ability.",
        prUrl: "https://github.com/xmtplabs/convos-assistants/pull/3454"
    )

    @Test("A default agent's header identity names no variant")
    func identityWithoutVariant() {
        let item: MessagesListItemType = .agentDmInfo(agentName: "Agent", variant: nil)
        #expect(item.id == "agent-dm-info-none")
    }

    @Test("A varianted agent's header identity carries the slug")
    func identityWithVariant() {
        let item: MessagesListItemType = .agentDmInfo(agentName: "Agent", variant: Self.stamp)
        #expect(item.id == "agent-dm-info-pr-3454")
    }

    @Test("A stamp arriving after first render changes the header's identity")
    func identityChangesWhenStampArrives() {
        let before: MessagesListItemType = .agentDmInfo(agentName: "Agent", variant: nil)
        let after: MessagesListItemType = .agentDmInfo(agentName: "Agent", variant: Self.stamp)
        #expect(before.id != after.id)
        #expect(before != after)
    }

    @Test("The header still explains an empty transcript with a variant attached")
    func explainsEmptyTranscriptWithVariant() {
        let item: MessagesListItemType = .agentDmInfo(agentName: "Agent", variant: Self.stamp)
        #expect(item.explainsAnEmptyTranscript)
    }
}
