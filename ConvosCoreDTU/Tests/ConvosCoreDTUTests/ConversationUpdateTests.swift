@testable import ConvosCore
import Foundation
import Testing

/// Phase 2 batch 2: migrated from
/// `ConvosCore/Tests/ConvosCoreTests/ConversationUpdateTests.swift`.
///
/// Pure-unit test — `ConversationUpdate` is a model type with derived
/// view-state (`addedAgent`, `addedVerifiedAssistant`, `summary`). It
/// never touches a `MessagingClient`, a database, or a backend, so the
/// migration is a mechanical re-host into the ConvosCoreDTU test target
/// where it validates that the model APIs remain reachable under the
/// same `@testable import ConvosCore` surface used by the DTU pass.
///
/// No DualBackendTestFixtures is needed — there's no backend to pick.
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
