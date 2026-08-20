import ConvosCore
import Foundation

/// One agent that has been handed a connection, identified by its
/// immutable inbox id (the same key extensions bind to).
struct ConnectionUsageAgent: Identifiable, Hashable, Sendable {
    let inboxId: String
    let displayName: String

    var id: String { inboxId }
}

/// One person who can use a connection: its owner, and -- once delegation
/// exists -- everyone they have handed it to.
struct ConnectionUsagePerson: Identifiable, Hashable, Sendable {
    let inboxId: String
    let displayName: String
    /// The connection's owner, i.e. the local member. Always the first row
    /// in the People section, which is why it is a flag rather than an
    /// inbox-id comparison the detail screen would have to make.
    let isOwner: Bool

    var id: String { inboxId }

    init(inboxId: String, displayName: String, isOwner: Bool = false) {
        self.inboxId = inboxId
        self.displayName = displayName
        self.isOwner = isOwner
    }

    /// The local member's row, labelled the way every other self row in the
    /// app is.
    static let owner: ConnectionUsagePerson = ConnectionUsagePerson(
        inboxId: "connection-usage-owner",
        displayName: "You",
        isOwner: true
    )
}

/// One conversation the connection is enabled in.
struct ConnectionUsageConversation: Identifiable, Hashable, Sendable {
    let conversationId: String
    let displayName: String

    var id: String { conversationId }
}

/// Where one connection is in use, as the detail screen renders it.
///
/// `people` carries **delegated** people only, and is empty today:
/// delegation to other members arrives with the Entitlement Actor Model,
/// and the wire already carries the rows behind it (`conversationAbilities`
/// drops every entry that is not `extendedByMe`). The owner's own row is
/// added by the detail view model, so the People section is never empty
/// whatever a source serves.
struct ConnectionUsage: Equatable, Sendable {
    var agents: [ConnectionUsageAgent]
    var people: [ConnectionUsagePerson]
    var conversations: [ConnectionUsageConversation]

    static let empty: ConnectionUsage = ConnectionUsage(agents: [], people: [], conversations: [])

    var isEmpty: Bool {
        agents.isEmpty && people.isEmpty && conversations.isEmpty
    }
}

/// One read of where every connection is in use.
///
/// `isUnavailable` is the difference between "nothing uses this" and "we
/// could not find out": with every conversation read failing, an empty map
/// is not a fact about the account. The surfaces render the two
/// differently -- silence about a connection the agent may well be using
/// is the misleading kind of empty.
struct ConnectionUsageSnapshot: Equatable, Sendable {
    var usageByAbilityId: [String: ConnectionUsage]
    var isUnavailable: Bool

    static let empty: ConnectionUsageSnapshot = ConnectionUsageSnapshot(usageByAbilityId: [:], isUnavailable: false)
    static let unavailable: ConnectionUsageSnapshot = ConnectionUsageSnapshot(usageByAbilityId: [:], isUnavailable: true)

    func usage(forAbilityId abilityId: String) -> ConnectionUsage {
        usageByAbilityId[abilityId] ?? .empty
    }
}

/// Resolves where connections are in use. The seam exists so the browser
/// and the detail screen can be driven from a session-backed source in the
/// app, a fixture in previews, and a stub in tests.
///
/// The whole-catalog read is the primitive, and the single-ability read is
/// derived from it, so the browser row's "Used in N convos" and the detail
/// screen's Convos section can never disagree: they are the same rows,
/// counted and listed. Deriving the count from the entitlement's
/// server-side `extensionCount` instead is what let the subtitle claim a
/// conversation the list could not show.
protocol ConnectionUsageSourcing: Sendable {
    func usageSnapshot() async -> ConnectionUsageSnapshot
}

extension ConnectionUsageSourcing {
    func usage(forAbilityId abilityId: String) async -> ConnectionUsage {
        await usageSnapshot().usage(forAbilityId: abilityId)
    }
}

/// Serves nothing. Previews and any surface reached before
/// `AbilitiesServices.configure` render zero states rather than stale rows.
struct EmptyConnectionUsageSource: ConnectionUsageSourcing {
    func usageSnapshot() async -> ConnectionUsageSnapshot {
        .empty
    }
}

/// Fixture source for previews and the debug mock path: the mock service's
/// extension fixtures crossed with named stand-in conversations, so both
/// render the same shape the session-backed source produces.
struct PreviewConnectionUsageSource: ConnectionUsageSourcing {
    private let underlying: ConversationConnectionUsageSource

    init(service: any AbilitiesServiceProtocol = MockAbilitiesService(artificialDelay: .zero)) {
        underlying = ConversationConnectionUsageSource(
            service: service,
            conversations: { Self.conversations }
        )
    }

    func usageSnapshot() async -> ConnectionUsageSnapshot {
        await underlying.usageSnapshot()
    }

    /// Named after `MockAbilitiesService.standardExtensions()`'s ids so the
    /// fixture opt-ins resolve to conversations with real-looking titles.
    static let conversations: [Conversation] = [
        mockConversation(id: "mock-conversation-1", name: "Weekend trip"),
        mockConversation(id: "mock-conversation-2", name: "Standup notes"),
        mockConversation(id: "mock-conversation-3", name: "No agent here", agentName: nil),
    ]

    private static func mockConversation(id: String, name: String, agentName: String? = "Caley") -> Conversation {
        var members: [ConversationMember] = [.mock(isCurrentUser: true)]
        if let agentName {
            members.append(
                ConversationMember(
                    profile: .mock(inboxId: "mock-agent-inbox-1", conversationId: id, name: agentName),
                    role: .member,
                    isCurrentUser: false,
                    isAgent: true
                )
            )
        }
        return .mock(id: id, name: name, members: members)
    }
}

/// Derives a connection's usage by fanning out over the caller's
/// conversations.
///
/// The backend serves no inverse of the per-conversation opt-in read: there
/// is `GET /v2/conversations/{id}/abilities`, but nothing that answers
/// "which conversations hold this ability", and the entitlement carries a
/// count (`extensionCount`) with no ids. Nothing is persisted client-side
/// either, so the names can only come from asking each conversation.
///
/// Two things keep that honest. Only conversations carrying an agent member
/// are asked at all -- an ability is extended to an agent, so a
/// conversation without one can never hold a row -- and at most
/// `maxConcurrentReads` reads are in flight. A conversation whose read
/// fails contributes nothing rather than failing the screen: a partial
/// answer beats an error where the alternative is a count with no names.
struct ConversationConnectionUsageSource: ConnectionUsageSourcing {
    let service: any AbilitiesServiceProtocol
    let conversations: @Sendable () async -> [Conversation]

    func usageSnapshot() async -> ConnectionUsageSnapshot {
        let candidates: [Conversation] = await conversations().filter(Self.mayHoldAbilities)
        guard !candidates.isEmpty else { return .empty }
        let reads: [Read] = await readAll(candidates)
        // Every conversation refused: an empty map here is ignorance, not
        // an answer, and the surfaces must say so rather than report that
        // nothing uses the connection.
        guard !reads.isEmpty else { return .unavailable }
        var usage: [String: ConnectionUsage] = [:]
        for abilityId in Self.abilityIds(in: reads) {
            let matches: [Match] = Self.matches(forAbilityId: abilityId, in: reads)
            usage[abilityId] = ConnectionUsage(
                agents: Self.agents(from: matches),
                people: [],
                conversations: Self.conversations(from: matches)
            )
        }
        return ConnectionUsageSnapshot(usageByAbilityId: usage, isUnavailable: false)
    }

    /// One conversation's opt-ins, as read.
    private struct Read: Sendable {
        let conversation: Conversation
        let rows: [ConversationAbility]
    }

    /// One conversation that holds a given ability, with the rows proving it.
    private struct Match: Sendable {
        let conversation: Conversation
        let rows: [ConversationAbility]
    }

    /// Which conversations are worth a request.
    ///
    /// An opt-in binds to an agent's inbox id, so a conversation that has
    /// never had an agent cannot hold one; a draft has no server-side
    /// conversation to hold one against. Everything else is asked,
    /// including conversations whose member list has not loaded yet -- an
    /// over-tight predicate here is exactly how the count and the list came
    /// to disagree, and the cost of one extra read is smaller than the cost
    /// of a row that cannot be shown.
    private static func mayHoldAbilities(_ conversation: Conversation) -> Bool {
        guard !conversation.isDraft else { return false }
        if conversation.isAgentDm || conversation.hasHadVerifiedAgent { return true }
        return conversation.members.contains { (member: ConversationMember) -> Bool in member.isAgent }
    }

    /// Every ability id anyone opted into, in first-seen order.
    private static func abilityIds(in reads: [Read]) -> [String] {
        var seen: Set<String> = []
        var ids: [String] = []
        for read in reads {
            for row in read.rows where !seen.contains(row.abilityId) {
                seen.insert(row.abilityId)
                ids.append(row.abilityId)
            }
        }
        return ids
    }

    private static func matches(forAbilityId abilityId: String, in reads: [Read]) -> [Match] {
        reads.compactMap { (read: Read) -> Match? in
            let rows: [ConversationAbility] = read.rows.filter { (row: ConversationAbility) -> Bool in
                row.abilityId == abilityId
            }
            guard !rows.isEmpty else { return nil }
            return Match(conversation: read.conversation, rows: rows)
        }
    }

    /// Reads in fixed-size batches and preserves the repository's ordering:
    /// each batch carries its slot in `candidates`, so results land where
    /// they were requested regardless of which read finishes first.
    private func readAll(_ candidates: [Conversation]) async -> [Read] {
        var reads: [Read] = []
        var start: Int = 0
        while start < candidates.count {
            let end: Int = min(start + Constant.maxConcurrentReads, candidates.count)
            let batch: [Conversation] = Array(candidates[start..<end])
            reads.append(contentsOf: await readBatch(batch))
            start = end
        }
        return reads
    }

    private func readBatch(_ batch: [Conversation]) async -> [Read] {
        var byIndex: [Int: Read] = [:]
        await withTaskGroup(of: (Int, Read?).self) { group in
            for (index, conversation) in batch.enumerated() {
                group.addTask {
                    let read: Read? = await self.read(conversation)
                    return (index, read)
                }
            }
            for await (index, read) in group {
                guard let read else { continue }
                byIndex[index] = read
            }
        }
        return byIndex.keys.sorted().compactMap { (index: Int) -> Read? in byIndex[index] }
    }

    private func read(_ conversation: Conversation) async -> Read? {
        do {
            let rows: [ConversationAbility] = try await service.conversationAbilities(conversationId: conversation.id)
            return Read(conversation: conversation, rows: rows)
        } catch {
            return nil
        }
    }

    /// Deduped by inbox id, first appearance wins: the same agent reached
    /// from two conversations is one agent.
    private static func agents(from matches: [Match]) -> [ConnectionUsageAgent] {
        var seen: Set<String> = []
        var agents: [ConnectionUsageAgent] = []
        for match in matches {
            for row in match.rows where !seen.contains(row.agentInboxId) {
                seen.insert(row.agentInboxId)
                agents.append(
                    ConnectionUsageAgent(
                        inboxId: row.agentInboxId,
                        displayName: displayName(forAgentInboxId: row.agentInboxId, in: match.conversation)
                    )
                )
            }
        }
        return agents
    }

    /// The agent's name as this conversation knows it; an agent whose
    /// profile has not resolved falls back to the generic label rather than
    /// rendering an inbox id.
    private static func displayName(forAgentInboxId inboxId: String, in conversation: Conversation) -> String {
        let member: ConversationMember? = conversation.members.first { (member: ConversationMember) -> Bool in
            member.profile.inboxId == inboxId
        }
        guard let member else { return Constant.unknownAgentName }
        let name: String = member.displayName.trimmingCharacters(in: .whitespacesAndNewlines)
        return name.isEmpty ? Constant.unknownAgentName : name
    }

    private static func conversations(from matches: [Match]) -> [ConnectionUsageConversation] {
        matches.map { (match: Match) -> ConnectionUsageConversation in
            ConnectionUsageConversation(
                conversationId: match.conversation.id,
                displayName: match.conversation.displayName
            )
        }
    }

    private enum Constant {
        static let maxConcurrentReads: Int = 4
        static let unknownAgentName: String = "Agent"
    }
}
