@testable import ConvosCore
import Foundation
import Testing

@Suite("ConversationUpdate Tests")
struct ConversationUpdateTests {
    private let creator: ConversationMember = .mock(isCurrentUser: true, name: "Me")

    private func update(addedMembers: [ConversationMember]) -> ConversationUpdate {
        ConversationUpdate(
            creator: creator,
            addedMembers: addedMembers,
            removedMembers: [],
            metadataChanges: []
        )
    }

    // MARK: - addedAgent

    @Test("addedAgent is true when any added member is an agent")
    func addedAgentTrueForUnverifiedAgent() {
        let agent = ConversationMember.mock(name: "CLI Bot", isAgent: true, agentVerification: .unverified)
        let update = update(addedMembers: [agent])
        #expect(update.addedAgent == true)
    }

    @Test("addedAgent is true when added member is a verified Convos assistant")
    func addedAgentTrueForVerifiedConvosAssistant() {
        let agent = ConversationMember.mock(name: "Convos Assistant", isAgent: true, agentVerification: .verified(.convos))
        let update = update(addedMembers: [agent])
        #expect(update.addedAgent == true)
    }

    @Test("addedAgent is false when no added member is an agent")
    func addedAgentFalseForRegularMembers() {
        let regular = ConversationMember.mock(name: "Alice", isAgent: false)
        let update = update(addedMembers: [regular])
        #expect(update.addedAgent == false)
    }

    // MARK: - addedVerifiedAssistant

    @Test("addedVerifiedAssistant is true only for verified Convos assistants")
    func addedVerifiedAssistantTrueForConvosAssistant() {
        let agent = ConversationMember.mock(name: "Convos Assistant", isAgent: true, agentVerification: .verified(.convos))
        let update = update(addedMembers: [agent])
        #expect(update.addedVerifiedAssistant == true)
    }

    @Test("addedVerifiedAssistant is false for unverified agents")
    func addedVerifiedAssistantFalseForUnverifiedAgent() {
        // This is the regression case: a CLI joiner advertises itself as
        // memberKind=agent but has no Convos attestation. The "See its skills"
        // button must NOT appear for these.
        let agent = ConversationMember.mock(name: "CLI Bot", isAgent: true, agentVerification: .unverified)
        let update = update(addedMembers: [agent])
        #expect(update.addedVerifiedAssistant == false)
    }

    @Test("addedVerifiedAssistant is false for user-OAuth verified agents")
    func addedVerifiedAssistantFalseForUserOAuthAgent() {
        // OAuth-verified agents are not Convos assistants and should not get
        // the "See its skills" affordance, which links to the Convos catalog.
        let agent = ConversationMember.mock(name: "OAuth Agent", isAgent: true, agentVerification: .verified(.userOAuth))
        let update = update(addedMembers: [agent])
        #expect(update.addedVerifiedAssistant == false)
    }

    @Test("addedVerifiedAssistant is false for regular members")
    func addedVerifiedAssistantFalseForRegularMembers() {
        let regular = ConversationMember.mock(name: "Alice", isAgent: false)
        let update = update(addedMembers: [regular])
        #expect(update.addedVerifiedAssistant == false)
    }

    @Test("addedVerifiedAssistant is true when at least one added member is a verified Convos assistant")
    func addedVerifiedAssistantTrueWithMixedMembers() {
        let regular = ConversationMember.mock(name: "Alice", isAgent: false)
        let unverified = ConversationMember.mock(name: "CLI Bot", isAgent: true, agentVerification: .unverified)
        let verified = ConversationMember.mock(name: "Convos Assistant", isAgent: true, agentVerification: .verified(.convos))
        let update = update(addedMembers: [regular, unverified, verified])
        #expect(update.addedVerifiedAssistant == true)
    }

    @Test("addedVerifiedAssistant is false for empty added members")
    func addedVerifiedAssistantFalseForEmpty() {
        let update = update(addedMembers: [])
        #expect(update.addedVerifiedAssistant == false)
    }
}
