@testable import ConvosCore
import Foundation
import Testing

// MARK: - Agent DM Empty-State Identity

/// The agent-DM empty state's identity carries the variant slug so a stamp that
/// lands after first render - the profile sync that fills in the agent
/// member - changes the item's id and forces the diffable data source to
/// rebuild the cell. Were the id constant, the empty state would keep rendering
/// its pre-sync self and the variant badge would never appear.
struct MessagesListItemTypeAgentDmInfoIdentityTests {
    private static let stamp: AgentVariantStamp = .init(
        slug: "pr-3454",
        label: "G Maps",
        whatToTest: "Places lookups run through the Maps ability.",
        prUrl: "https://github.com/xmtplabs/convos-assistants/pull/3454"
    )

    @Test("A default agent's empty-state identity names no variant")
    func identityWithoutVariant() {
        let item: MessagesListItemType = .agentDmInfo(agentName: "Agent", variant: nil)
        #expect(item.id == "agent-dm-info-none")
    }

    @Test("A varianted agent's empty-state identity carries the slug")
    func identityWithVariant() {
        let item: MessagesListItemType = .agentDmInfo(agentName: "Agent", variant: Self.stamp)
        #expect(item.id == "agent-dm-info-pr-3454")
    }

    @Test("A stamp arriving after first render changes the empty state's identity")
    func identityChangesWhenStampArrives() {
        let before: MessagesListItemType = .agentDmInfo(agentName: "Agent", variant: nil)
        let after: MessagesListItemType = .agentDmInfo(agentName: "Agent", variant: Self.stamp)
        #expect(before.id != after.id)
        #expect(before != after)
    }

    @Test("The empty state explains an empty transcript with a variant attached")
    func explainsEmptyTranscriptWithVariant() {
        let item: MessagesListItemType = .agentDmInfo(agentName: "Agent", variant: Self.stamp)
        #expect(item.explainsAnEmptyTranscript)
    }
}

@Suite("MessagesListItemType group empty state identity")
struct MessagesListItemTypeGroupEmptyStateIdentityTests {
    @Test("The group empty state keeps a stable identity when invite availability changes")
    func identityIsStable() {
        let enabled: MessagesListItemType = .groupEmptyState(isInviteEnabled: true)
        let disabled: MessagesListItemType = .groupEmptyState(isInviteEnabled: false)

        #expect(enabled.id == "group-empty-state")
        #expect(enabled.id == disabled.id)
        #expect(enabled != disabled)
    }

    @Test("The group empty state explains an empty transcript")
    func explainsEmptyTranscript() {
        let item: MessagesListItemType = .groupEmptyState(isInviteEnabled: true)
        #expect(item.explainsAnEmptyTranscript)
    }
}
