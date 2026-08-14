import Foundation
import GRDB
import Testing
@testable import ConvosCore

/// Covers folding a group's agent DM into its conversations-list row. The DM is
/// a separate conversation, and the row renders its last message as the
/// preview, so which link the list follows to find it decides whether that
/// preview is stable.
@Suite("Agent DM Fold Tests", .serialized)
struct AgentDmFoldTests {
    private static let currentInboxId: String = "inbox-current"
    private static let agentInboxId: String = "inbox-agent"
    private static let groupId: String = "group-1"
    private static let dmId: String = "dm-1"
    private static let dmMessageText: String = "Hey Jarod!"

    @Test("A row folds in the last message from its agent DM")
    func foldsAgentDmPreview() throws {
        let queue = try Self.migratedQueue()
        try queue.write { try Self.seed($0) }

        let summary = try Self.foldedSummary(queue)

        #expect(summary?.lastMessage?.text == Self.dmMessageText)
        #expect(summary?.inboxId == Self.agentInboxId)
        #expect(summary?.displayName == "Agent")
    }

    /// The regression. A group's membership rows are rewritten by member sync
    /// and can be missing the agent entirely, but the DM carrying the messages
    /// is untouched. Resolving the DM from the group's members made the preview
    /// disappear in exactly this state; the recorded origin link does not.
    @Test("A group missing the agent's member row still folds its DM")
    func foldsWhenGroupMemberRowIsMissing() throws {
        let queue = try Self.migratedQueue()
        try queue.write { try Self.seed($0, groupHasAgentMember: false) }

        let summary = try Self.foldedSummary(queue)

        #expect(summary?.lastMessage?.text == Self.dmMessageText)
        #expect(summary?.inboxId == Self.agentInboxId)
    }

    /// A DM saved before the origin link existed has no link row until its next
    /// save, so the group's agent member stays the fallback path.
    @Test("A DM with no recorded origin folds through the group's agent member")
    func foldsLegacyDmThroughGroupMembers() throws {
        let queue = try Self.migratedQueue()
        try queue.write { try Self.seed($0, withOrigin: false) }

        #expect(try Self.foldedSummary(queue)?.lastMessage?.text == Self.dmMessageText)
    }

    /// Guards the premise: with neither the link nor the member row there is
    /// nothing to fold, so the row falls back to the group's own lane.
    @Test("A group with no link and no agent member folds nothing")
    func foldsNothingWithoutLinkOrMember() throws {
        let queue = try Self.migratedQueue()
        try queue.write { try Self.seed($0, groupHasAgentMember: false, withOrigin: false) }

        #expect(try Self.foldedSummary(queue) == nil)
    }

    // MARK: - Helpers

    private static func foldedSummary(_ queue: DatabaseQueue) throws -> Conversation.AgentDmSummary? {
        let repository = ConversationsRepository(dbReader: queue, consent: [.allowed, .unknown])
        let conversations = try repository.fetchAll()
        return conversations.first { $0.id == groupId }?.agentDm
    }

    private static func migratedQueue() throws -> DatabaseQueue {
        let queue = try DatabaseQueue()
        try SharedDatabaseMigrator.shared.migrate(database: queue)
        return queue
    }

    /// Seeds a group and its 2-member agent DM (current user + verified agent),
    /// with one agent message in the DM. `groupHasAgentMember` controls whether
    /// the agent also has a membership row in the group; `withOrigin` controls
    /// whether the DM -> group link is recorded.
    private static func seed(
        _ db: Database,
        groupHasAgentMember: Bool = true,
        withOrigin: Bool = true
    ) throws {
        try DBMember(inboxId: currentInboxId).save(db, onConflict: .ignore)
        try DBMember(inboxId: agentInboxId).save(db, onConflict: .ignore)
        try DBInbox(inboxId: currentInboxId, clientId: "client-current").save(db, onConflict: .ignore)
        try DBProfile(
            inboxId: agentInboxId,
            name: "Agent",
            memberKind: .verifiedConvos,
            profileSource: .profileUpdate,
            updatedAt: Date()
        ).save(db)

        try makeConversation(id: groupId, isAgentDm: false).insert(db)
        try makeConversation(id: dmId, isAgentDm: true).insert(db)
        try makeLocalState(for: groupId).insert(db)
        try makeLocalState(for: dmId).insert(db)

        try member(conversationId: groupId, inboxId: currentInboxId, role: .superAdmin).insert(db)
        if groupHasAgentMember {
            try member(conversationId: groupId, inboxId: agentInboxId, role: .member).insert(db)
        }
        try member(conversationId: dmId, inboxId: currentInboxId, role: .superAdmin).insert(db)
        try member(conversationId: dmId, inboxId: agentInboxId, role: .member).insert(db)

        try DBMessage(
            id: "dm-message-1",
            clientMessageId: "dm-message-1",
            conversationId: dmId,
            senderId: agentInboxId,
            dateNs: 1_000,
            date: Date(timeIntervalSince1970: 1),
            sortId: 1_000,
            status: .published,
            messageType: .original,
            contentType: .text,
            text: dmMessageText,
            emoji: nil,
            invite: nil,
            linkPreview: nil,
            sourceMessageId: nil,
            attachmentUrls: [],
            update: nil
        ).insert(db)

        if withOrigin {
            try DBAgentDmOrigin.record(conversationId: dmId, originConversationId: groupId, in: db)
        }
    }

    private static func member(
        conversationId: String,
        inboxId: String,
        role: MemberRole
    ) -> DBConversationMember {
        DBConversationMember(
            conversationId: conversationId,
            inboxId: inboxId,
            role: role,
            consent: .allowed,
            createdAt: Date(),
            invitedByInboxId: nil
        )
    }

    private static func makeLocalState(for conversationId: String) -> ConversationLocalState {
        ConversationLocalState(
            conversationId: conversationId,
            isPinned: false,
            isUnread: false,
            isUnreadUpdatedAt: Date(),
            isMuted: false,
            pinnedOrder: nil,
            hidesInviteCard: false,
            leftHostedInviteSession: false,
            wasRemoved: false,
            hasHadOtherMembers: true,
            hasSharedInvite: false
        )
    }

    private static func makeConversation(id: String, isAgentDm: Bool) -> DBConversation {
        DBConversation(
            id: id,
            clientConversationId: "client-\(id)",
            inviteTag: "tag-\(id)",
            creatorId: currentInboxId,
            kind: .group,
            consent: .allowed,
            createdAt: Date(timeIntervalSince1970: 0),
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
            hasHadVerifiedAgent: false,
            isAgentDm: isAgentDm
        )
    }
}
