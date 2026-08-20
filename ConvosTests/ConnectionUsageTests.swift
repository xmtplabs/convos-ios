@testable import Convos
import ConvosCore
import XCTest

/// The connection detail screen's three sections, derived by fanning out
/// over the caller's conversations because the backend serves no inverse of
/// the per-conversation opt-in read.
final class ConnectionUsageTests: XCTestCase {
    func testConversationsSectionNamesEveryConvoHoldingTheAbility() async {
        let source = Self.makeSource(conversations: Self.standardConversations)

        let usage = await source.usage(forAbilityId: "googlecalendar")

        XCTAssertEqual(usage.conversations.map(\.displayName), ["Weekend trip", "Standup notes"])
        XCTAssertEqual(usage.conversations.map(\.conversationId), ["mock-conversation-1", "mock-conversation-2"])
    }

    /// The fixture extends Coinbase to conversation one only, so the second
    /// conversation must not come along for the ride.
    func testConversationsSectionExcludesConvosWithoutTheAbility() async {
        let source = Self.makeSource(conversations: Self.standardConversations)

        let usage = await source.usage(forAbilityId: "coinbase")

        XCTAssertEqual(usage.conversations.map(\.conversationId), ["mock-conversation-1"])
    }

    func testAbilityNobodyEnabledProducesNoSections() async {
        let source = Self.makeSource(conversations: Self.standardConversations)

        let usage = await source.usage(forAbilityId: "youtube")

        XCTAssertTrue(usage.isEmpty)
    }

    /// One agent reached from two conversations is one agent, named the way
    /// its conversation knows it.
    func testAgentsSectionDedupesTheSameAgentAcrossConvos() async {
        let source = Self.makeSource(conversations: Self.standardConversations)

        let usage = await source.usage(forAbilityId: "googlecalendar")

        XCTAssertEqual(usage.agents.map(\.inboxId), ["mock-agent-inbox-1"])
        XCTAssertEqual(usage.agents.map(\.displayName), ["Caley"])
    }

    func testAgentsSectionListsEveryDistinctAgent() async {
        let service = MockAbilitiesService(artificialDelay: .zero)
        try? await service.extendAbility(
            conversationId: "mock-conversation-2",
            abilityId: "googlecalendar",
            agentInboxId: "second-agent",
            bundleIds: ["calendar.events"]
        )
        let conversations: [Conversation] = [
            Self.conversation(id: "mock-conversation-1", name: "Weekend trip", agents: [("mock-agent-inbox-1", "Caley")]),
            Self.conversation(
                id: "mock-conversation-2",
                name: "Standup notes",
                agents: [("mock-agent-inbox-1", "Caley"), ("second-agent", "Rosetta")]
            ),
        ]
        let source = ConversationConnectionUsageSource(service: service, conversations: { conversations })

        let usage = await source.usage(forAbilityId: "googlecalendar")

        XCTAssertEqual(usage.agents.map(\.inboxId), ["mock-agent-inbox-1", "second-agent"])
        XCTAssertEqual(usage.agents.map(\.displayName), ["Caley", "Rosetta"])
    }

    /// An opt-in binds to an agent's inbox id, so a conversation that has
    /// never had an agent cannot hold one and is not worth a request. A
    /// draft has no server-side conversation to hold one against either.
    func testConversationsThatCannotHoldAnOptInAreNeverRead() async {
        let service = RecordingAbilitiesService(underlying: MockAbilitiesService(artificialDelay: .zero))
        let conversations: [Conversation] = Self.standardConversations + [
            Self.conversation(id: "mock-conversation-9", name: "People only", agents: []),
            Self.conversation(id: "draft-mock-conversation-8", name: "Draft", agents: [("mock-agent-inbox-1", "Caley")]),
        ]
        let source = ConversationConnectionUsageSource(service: service, conversations: { conversations })

        let usage = await source.usage(forAbilityId: "googlecalendar")

        let read: [String] = await service.readConversationIds
        XCTAssertEqual(Set(read), ["mock-conversation-1", "mock-conversation-2"])
        XCTAssertEqual(usage.conversations.count, 2)
    }

    /// A conversation whose members have not loaded yet is still asked: an
    /// over-tight predicate here is what let the browser's count claim a
    /// convo the detail screen could not name.
    func testAConversationWithAnUnloadedMemberListIsStillRead() async {
        let service = RecordingAbilitiesService(underlying: MockAbilitiesService(artificialDelay: .zero))
        var mutable: Conversation = .mock(
            id: "mock-conversation-2",
            name: "Members not loaded",
            members: [.mock(isCurrentUser: true)]
        )
        mutable.isAgentDm = true
        let unloaded: Conversation = mutable
        let source = ConversationConnectionUsageSource(service: service, conversations: { [unloaded] })

        let usage = await source.usage(forAbilityId: "googlecalendar")

        let read: [String] = await service.readConversationIds
        XCTAssertEqual(read, ["mock-conversation-2"])
        XCTAssertEqual(usage.conversations.map(\.conversationId), ["mock-conversation-2"])
        XCTAssertEqual(usage.agents.map(\.displayName), ["Agent"], "an unresolved agent is labelled, never rendered as an inbox id")
    }

    /// No source writes a delegated person yet: delegation to other members
    /// arrives with the Entitlement Actor Model, and until then no fixture,
    /// however populated, may put a row there.
    func testNoDelegatedPeopleAreEverSourced() async {
        let source = Self.makeSource(conversations: Self.standardConversations)

        for abilityId in ["googlecalendar", "coinbase", "youtube"] {
            let usage = await source.usage(forAbilityId: abilityId)
            XCTAssertTrue(usage.people.isEmpty, "ability \(abilityId)")
        }
    }

    /// The People section is never empty: the owner's own row leads it
    /// whatever the source serves, including an ability nobody enabled
    /// anywhere and a source that answers nothing at all.
    @MainActor
    func testPeopleAlwaysLeadsWithTheOwnersOwnRow() async throws {
        let ability = try XCTUnwrap(MockAbilitiesService.standardCatalog().first { $0.id == "youtube" })
        let sources: [any ConnectionUsageSourcing] = [
            Self.makeSource(conversations: Self.standardConversations),
            EmptyConnectionUsageSource(),
        ]

        for source in sources {
            let viewModel = AbilityDetailViewModel(ability: ability, usageSource: source)
            await viewModel.refresh()
            XCTAssertEqual(viewModel.people.map(\.displayName), ["You"])
            XCTAssertEqual(viewModel.people.first?.isOwner, true)
        }
    }

    /// A read that throws contributes nothing rather than failing the
    /// screen: the surviving conversations still get named.
    func testAFailedReadDropsOnlyItsOwnConversation() async {
        let service = RecordingAbilitiesService(
            underlying: MockAbilitiesService(artificialDelay: .zero),
            failingConversationIds: ["mock-conversation-1"]
        )
        let source = ConversationConnectionUsageSource(service: service, conversations: { Self.standardConversations })

        let usage = await source.usage(forAbilityId: "googlecalendar")

        XCTAssertEqual(usage.conversations.map(\.conversationId), ["mock-conversation-2"])
    }

    /// The reported mismatch: the browser row said "Used in 2 convos" while
    /// the detail screen could name one. The subtitle read the entitlement's
    /// server-side `extensionCount`, which counts conversations this client
    /// has no row for. Both now come from one read, so the count is the
    /// length of the list by construction.
    @MainActor
    func testTheBrowserCountIsExactlyWhatTheDetailScreenLists() async throws {
        let service = MockAbilitiesService(artificialDelay: .zero)
        let visible: [Conversation] = [
            Self.conversation(id: "mock-conversation-1", name: "Weekend trip", agents: [("mock-agent-inbox-1", "Caley")])
        ]
        let usageSource = ConversationConnectionUsageSource(service: service, conversations: { visible })
        let listViewModel = AbilitiesListViewModel(service: service, usageSource: usageSource)

        await listViewModel.refresh()
        let detailViewModel = AbilityDetailViewModel(
            ability: try XCTUnwrap(listViewModel.entitledAbilities.first { $0.id == "googlecalendar" }),
            usageSource: usageSource
        )
        await detailViewModel.refresh()

        let serverCount: Int = detailViewModel.ability.entitlement?.extensionCount ?? 0
        XCTAssertEqual(serverCount, 2, "fixture guard: the backend still counts a convo this client cannot show")
        XCTAssertEqual(detailViewModel.conversations.count, 1)
        XCTAssertEqual(listViewModel.conversationCount(forAbilityId: "googlecalendar"), detailViewModel.conversations.count)
    }

    func testNoConversationsProducesEmptyUsage() async {
        let source = Self.makeSource(conversations: [])

        let usage = await source.usage(forAbilityId: "googlecalendar")

        XCTAssertEqual(usage, .empty)
    }

    // MARK: - Fixtures

    private static func makeSource(conversations: [Conversation]) -> ConversationConnectionUsageSource {
        ConversationConnectionUsageSource(
            service: MockAbilitiesService(artificialDelay: .zero),
            conversations: { conversations }
        )
    }

    /// Mirrors `MockAbilitiesService.standardExtensions()`: Google Calendar
    /// in both conversations, Coinbase in the first only.
    private static var standardConversations: [Conversation] {
        [
            conversation(id: "mock-conversation-1", name: "Weekend trip", agents: [("mock-agent-inbox-1", "Caley")]),
            conversation(id: "mock-conversation-2", name: "Standup notes", agents: [("mock-agent-inbox-1", "Caley")]),
        ]
    }

    fileprivate static func conversation(id: String, name: String, agents: [(String, String)]) -> Conversation {
        var members: [ConversationMember] = [.mock(isCurrentUser: true)]
        for agent in agents {
            members.append(
                ConversationMember(
                    profile: .mock(inboxId: agent.0, conversationId: id, name: agent.1),
                    role: .member,
                    isCurrentUser: false,
                    isAgent: true
                )
            )
        }
        return .mock(id: id, name: name, members: members)
    }
}

/// Records which conversations were actually read, and can fail chosen
/// ones. Only `conversationAbilities` is exercised; the rest forwards.
private actor RecordingAbilitiesService: AbilitiesServiceProtocol {
    private let underlying: MockAbilitiesService
    private let failingConversationIds: Set<String>
    private(set) var readConversationIds: [String] = []

    init(underlying: MockAbilitiesService, failingConversationIds: Set<String> = []) {
        self.underlying = underlying
        self.failingConversationIds = failingConversationIds
    }

    func fetchCatalog() async throws -> AbilitiesCatalog {
        try await underlying.fetchCatalog()
    }

    func beginEntitlement(abilityId: String) async throws -> AbilityEntitlementInitiation {
        try await underlying.beginEntitlement(abilityId: abilityId)
    }

    func completeEntitlement(abilityId: String) async throws {
        try await underlying.completeEntitlement(abilityId: abilityId)
    }

    func revokeEntitlement(abilityId: String) async throws {
        try await underlying.revokeEntitlement(abilityId: abilityId)
    }

    func conversationAbilities(conversationId: String) async throws -> [ConversationAbility] {
        readConversationIds.append(conversationId)
        if failingConversationIds.contains(conversationId) {
            throw AbilitiesServiceError.unknownAbility(abilityId: conversationId)
        }
        return try await underlying.conversationAbilities(conversationId: conversationId)
    }

    func extendAbility(conversationId: String, abilityId: String, agentInboxId: String, bundleIds: [String]) async throws {
        try await underlying.extendAbility(
            conversationId: conversationId,
            abilityId: abilityId,
            agentInboxId: agentInboxId,
            bundleIds: bundleIds
        )
    }

    func withdrawAbility(conversationId: String, abilityId: String, agentInboxId: String) async throws {
        try await underlying.withdrawAbility(
            conversationId: conversationId,
            abilityId: abilityId,
            agentInboxId: agentInboxId
        )
    }
}
