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

    @Test("addedAgent is true when added member is a verified Convos agent")
    func addedAgentTrueForVerifiedConvosAgent() {
        let agent = ConversationMember.mock(name: "Convos Agent", isAgent: true, agentVerification: .verified(.convos))
        let update = update(addedMembers: [agent])
        #expect(update.addedAgent == true)
    }

    @Test("addedAgent is false when no added member is an agent")
    func addedAgentFalseForRegularMembers() {
        let regular = ConversationMember.mock(name: "Alice", isAgent: false)
        let update = update(addedMembers: [regular])
        #expect(update.addedAgent == false)
    }

    // MARK: - addedVerifiedAgent

    @Test("addedVerifiedAgent is true only for verified Convos agents")
    func addedVerifiedAgentTrueForConvosAgent() {
        let agent = ConversationMember.mock(name: "Convos Agent", isAgent: true, agentVerification: .verified(.convos))
        let update = update(addedMembers: [agent])
        #expect(update.addedVerifiedAgent == true)
    }

    @Test("addedVerifiedAgent is false for unverified agents")
    func addedVerifiedAgentFalseForUnverifiedAgent() {
        // This is the regression case: a CLI joiner advertises itself as
        // memberKind=agent but has no Convos attestation, so it must not be
        // treated as a verified Convos agent (e.g. for contact-card anchoring).
        let agent = ConversationMember.mock(name: "CLI Bot", isAgent: true, agentVerification: .unverified)
        let update = update(addedMembers: [agent])
        #expect(update.addedVerifiedAgent == false)
    }

    @Test("addedVerifiedAgent is false for user-OAuth verified agents")
    func addedVerifiedAgentFalseForUserOAuthAgent() {
        // OAuth-verified agents are not Convos agents and should not be
        // treated as verified Convos agents.
        let agent = ConversationMember.mock(name: "OAuth Agent", isAgent: true, agentVerification: .verified(.userOAuth))
        let update = update(addedMembers: [agent])
        #expect(update.addedVerifiedAgent == false)
    }

    @Test("addedVerifiedAgent is false for regular members")
    func addedVerifiedAgentFalseForRegularMembers() {
        let regular = ConversationMember.mock(name: "Alice", isAgent: false)
        let update = update(addedMembers: [regular])
        #expect(update.addedVerifiedAgent == false)
    }

    @Test("addedVerifiedAgent is true when at least one added member is a verified Convos agent")
    func addedVerifiedAgentTrueWithMixedMembers() {
        let regular = ConversationMember.mock(name: "Alice", isAgent: false)
        let unverified = ConversationMember.mock(name: "CLI Bot", isAgent: true, agentVerification: .unverified)
        let verified = ConversationMember.mock(name: "Convos Agent", isAgent: true, agentVerification: .verified(.convos))
        let update = update(addedMembers: [regular, unverified, verified])
        #expect(update.addedVerifiedAgent == true)
    }

    @Test("addedVerifiedAgent is false for empty added members")
    func addedVerifiedAgentFalseForEmpty() {
        let update = update(addedMembers: [])
        #expect(update.addedVerifiedAgent == false)
    }

    // MARK: - summary for metadata changes

    private func metadataUpdate(
        creator: ConversationMember,
        field: ConversationUpdate.MetadataChange.Field,
        oldValue: String? = nil,
        newValue: String?
    ) -> ConversationUpdate {
        ConversationUpdate(
            creator: creator,
            addedMembers: [],
            removedMembers: [],
            metadataChanges: [
                .init(field: field, oldValue: oldValue, newValue: newValue)
            ]
        )
    }

    @Test("summary uses 'changed the convo name to' for a non-empty new name")
    func summaryRenamesToNonEmptyName() {
        let update = metadataUpdate(creator: creator, field: .name, newValue: "Fam")
        #expect(update.summary == "You changed the convo name to \"Fam\"")
    }

    @Test("summary says 'removed the convo name' when the new name is empty")
    func summaryClearsName() {
        // Regression: clearing the name field used to render
        // `You changed the convo name to ""`. It should read
        // `You removed the convo name` instead.
        let update = metadataUpdate(creator: creator, field: .name, newValue: "")
        #expect(update.summary == "You removed the convo name")
    }

    @Test("summary attributes the rename to the other member when not current user")
    func summaryRenamesByOtherMember() {
        let alice = ConversationMember.mock(isCurrentUser: false, name: "Alice")
        let update = metadataUpdate(creator: alice, field: .name, newValue: "")
        #expect(update.summary == "Alice removed the convo name")
    }

    @Test("summary uses 'changed the convo description to' for a non-empty new description")
    func summaryRenamesDescriptionToNonEmpty() {
        let update = metadataUpdate(creator: creator, field: .description, newValue: "plans for the weekend")
        #expect(update.summary == "You changed the convo description to \"plans for the weekend\"")
    }

    @Test("summary says 'removed the convo description' when the new description is empty")
    func summaryClearsDescription() {
        let update = metadataUpdate(creator: creator, field: .description, newValue: "")
        #expect(update.summary == "You removed the convo description")
    }
}
