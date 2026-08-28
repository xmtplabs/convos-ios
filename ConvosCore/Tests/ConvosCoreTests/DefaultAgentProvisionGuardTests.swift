@testable import ConvosCore
import Foundation
import GRDB
import Testing

/// Coverage for the predicate that decides whether the default-agent
/// provisioner runs. It used to ask "does this conversation lack a second
/// member?", which is only equivalent to "does it lack an agent?" for the
/// warm-cache conversation it was written against — the creator alone in a
/// fresh row. For any conversation that has people in it the old question
/// answered "an agent is already here", so the user-initiated "Add an agent"
/// tap provisioned nothing. These pin the question it asks now.
@Suite("Default agent provision guard")
struct DefaultAgentProvisionGuardTests {
    private static let currentInboxId: String = "inbox-current"
    private static let humanInboxId: String = "inbox-human"
    private static let agentInboxId: String = "inbox-agent"

    @Test("A conversation with only the creator still needs an agent")
    func creatorAloneLacksAgent() async throws {
        let session = try makeSession { db in
            try Self.seedConversation(db: db, id: "c1", memberInboxIds: [Self.currentInboxId])
        }

        #expect(try await session.conversationLacksAgent("c1") == true)
    }

    /// The regression. A group with other people but no agent must still
    /// provision — this is the case the old member-count guard dropped.
    @Test("A conversation with human members but no agent still needs one")
    func humanMembersStillLackAgent() async throws {
        let session = try makeSession { db in
            try Self.seedHuman(db: db, inboxId: Self.humanInboxId)
            try Self.seedConversation(
                db: db,
                id: "c2",
                memberInboxIds: [Self.currentInboxId, Self.humanInboxId]
            )
        }

        #expect(try await session.conversationLacksAgent("c2") == true)
    }

    @Test("A conversation with an agent member does not need another")
    func agentMemberIsDetected() async throws {
        let session = try makeSession { db in
            try Self.seedAgent(db: db, inboxId: Self.agentInboxId, kind: .verifiedConvos)
            try Self.seedConversation(
                db: db,
                id: "c3",
                memberInboxIds: [Self.currentInboxId, Self.agentInboxId]
            )
        }

        #expect(try await session.conversationLacksAgent("c3") == false)
    }

    /// An agent that has joined but not yet verified is still an agent. This
    /// is why the predicate reads member kind and not `hasHadVerifiedAgent`
    /// alone — verification lands later, and a second provision in that
    /// window would seat a duplicate.
    @Test("An unverified agent member counts as an agent")
    func unverifiedAgentMemberIsDetected() async throws {
        let session = try makeSession { db in
            try Self.seedAgent(db: db, inboxId: Self.agentInboxId, kind: .agent)
            try Self.seedConversation(
                db: db,
                id: "c4",
                memberInboxIds: [Self.currentInboxId, Self.agentInboxId]
            )
        }

        #expect(try await session.conversationLacksAgent("c4") == false)
    }

    /// The sticky historical answer, for a conversation whose agent has since
    /// left or whose profile row hasn't synced.
    @Test("hasHadVerifiedAgent alone is enough to skip")
    func stickyVerifiedFlagSkips() async throws {
        let session = try makeSession { db in
            try Self.seedConversation(
                db: db,
                id: "c5",
                memberInboxIds: [Self.currentInboxId],
                hasHadVerifiedAgent: true
            )
        }

        #expect(try await session.conversationLacksAgent("c5") == false)
    }

    // MARK: - Helpers

    private func makeSession(seed: (Database) throws -> Void) throws -> SessionManager {
        let databaseManager = MockDatabaseManager.makeTestDatabase()
        try databaseManager.dbWriter.write { db in
            try Self.seedInbox(db: db)
            try seed(db)
        }
        return SessionManager(
            databaseWriter: databaseManager.dbWriter,
            databaseReader: databaseManager.dbReader,
            environment: .tests,
            identityStore: MockKeychainIdentityStore(),
            platformProviders: .mock
        )
    }

    private static func seedInbox(db: Database) throws {
        try DBMember(inboxId: currentInboxId).save(db, onConflict: .ignore)
        try DBInbox(
            inboxId: currentInboxId,
            clientId: "client-current",
            createdAt: Date()
        ).save(db, onConflict: .ignore)
    }

    /// A human member: a `profile` row with no `memberKind`.
    private static func seedHuman(db: Database, inboxId: String) throws {
        try DBMember(inboxId: inboxId).save(db, onConflict: .ignore)
        try DBProfile(
            inboxId: inboxId,
            name: "Human",
            memberKind: nil,
            profileSource: .profileUpdate,
            updatedAt: Date()
        ).save(db)
    }

    private static func seedAgent(db: Database, inboxId: String, kind: DBMemberKind) throws {
        try DBMember(inboxId: inboxId).save(db, onConflict: .ignore)
        try DBProfile(
            inboxId: inboxId,
            name: "Agent",
            memberKind: kind,
            profileSource: .profileUpdate,
            updatedAt: Date()
        ).save(db)
    }

    private static func seedConversation(
        db: Database,
        id: String,
        memberInboxIds: [String],
        hasHadVerifiedAgent: Bool = false
    ) throws {
        try DBConversation(
            id: id,
            clientConversationId: "client-\(id)",
            inviteTag: "tag-\(id)",
            creatorId: currentInboxId,
            kind: .group,
            consent: .allowed,
            createdAt: Date(),
            name: nil,
            description: nil,
            imageURLString: nil,
            publicImageURLString: nil,
            includeInfoInPublicPreview: false,
            expiresAt: nil,
            debugInfo: .empty,
            isLocked: false,
            imageSalt: nil,
            imageNonce: nil,
            imageEncryptionKey: nil,
            conversationEmoji: nil,
            imageLastRenewed: nil,
            isUnused: false,
            hasHadVerifiedAgent: hasHadVerifiedAgent
        ).insert(db)

        for (index, inboxId) in memberInboxIds.enumerated() {
            try DBConversationMember(
                conversationId: id,
                inboxId: inboxId,
                role: index == 0 ? .superAdmin : .member,
                consent: .allowed,
                createdAt: Date(),
                invitedByInboxId: nil
            ).insert(db)
        }
    }
}
