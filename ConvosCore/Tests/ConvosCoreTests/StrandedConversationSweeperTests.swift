@testable import ConvosCore
import Foundation
import GRDB
import Testing

/// Coverage for `StrandedConversationSweeper`: the session-start cleanup for
/// visible, unnamed, agent-less conversation shells stranded by earlier
/// builds' eager DM creates. The sweep must hide exactly those shells and
/// leave every conversation with any sign of user intent untouched.
@Suite("Stranded conversation sweeper", .serialized)
struct StrandedConversationSweeperTests {
    private static let selfInbox = "self-inbox"
    private static let otherInbox = "other-inbox"
    private static let oldDate = Date().addingTimeInterval(-3 * 24 * 60 * 60)

    private func makeDatabase() throws -> DatabaseQueue {
        let dbQueue = try DatabaseQueue()
        try SharedDatabaseMigrator.shared.migrate(database: dbQueue)
        return dbQueue
    }

    private func seedInbox(_ db: Database) throws {
        try DBMember(inboxId: Self.selfInbox).save(db, onConflict: .ignore)
        try DBInbox(inboxId: Self.selfInbox, clientId: "client-1", createdAt: Date()).insert(db)
    }

    private func seedMember(_ db: Database, conversationId: String, inboxId: String) throws {
        try DBMember(inboxId: inboxId).save(db, onConflict: .ignore)
        try DBConversationMember(
            conversationId: conversationId,
            inboxId: inboxId,
            role: .member,
            consent: .allowed,
            createdAt: Self.oldDate,
            invitedByInboxId: nil
        ).save(db)
    }

    // swiftlint:disable:next function_parameter_count
    private func seedConversation(
        _ db: Database,
        id: String,
        createdAt: Date,
        name: String?,
        creatorId: String,
        isAgentDm: Bool,
        otherMemberInboxId: String?,
        isPinned: Bool,
        hasSharedInvite: Bool,
        hasHadOtherMembers: Bool
    ) throws {
        try DBConversation(
            id: id,
            clientConversationId: "draft-\(id)",
            inviteTag: "tag-\(id)",
            creatorId: creatorId,
            kind: .group,
            consent: .allowed,
            createdAt: createdAt,
            name: name,
            description: nil,
            imageURLString: nil,
            publicImageURLString: nil,
            includeInfoInPublicPreview: true,
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
        ).insert(db)
        try ConversationLocalState(
            conversationId: id,
            isPinned: isPinned,
            isUnread: false,
            isUnreadUpdatedAt: Date.distantPast,
            isMuted: false,
            pinnedOrder: nil,
            hidesInviteCard: false,
            leftHostedInviteSession: false,
            wasRemoved: false,
            hasHadOtherMembers: hasHadOtherMembers,
            hasSharedInvite: hasSharedInvite
        ).insert(db)
        try seedMember(db, conversationId: id, inboxId: Self.selfInbox)
        if let otherMemberInboxId {
            try seedMember(db, conversationId: id, inboxId: otherMemberInboxId)
        }
    }

    /// A canonical stranded shell: old, visible, self-created, unnamed,
    /// self-only, untouched local state.
    private func seedShell(_ db: Database, id: String, createdAt: Date = oldDate) throws {
        try seedConversation(
            db,
            id: id,
            createdAt: createdAt,
            name: nil,
            creatorId: Self.selfInbox,
            isAgentDm: false,
            otherMemberInboxId: nil,
            isPinned: false,
            hasSharedInvite: false,
            hasHadOtherMembers: false
        )
    }

    private func seedMessage(
        _ db: Database,
        conversationId: String,
        id: String,
        contentType: MessageContentType
    ) throws {
        try DBMessage(
            id: id,
            clientMessageId: id,
            conversationId: conversationId,
            senderId: Self.selfInbox,
            dateNs: 1_000,
            date: Self.oldDate,
            sortId: 1_000,
            status: .published,
            messageType: .original,
            contentType: contentType,
            text: contentType == .text ? "hello" : nil,
            emoji: nil,
            invite: nil,
            linkPreview: nil,
            sourceMessageId: nil,
            attachmentUrls: [],
            update: nil
        ).insert(db)
    }

    private func isUnused(_ dbQueue: DatabaseQueue, _ id: String) throws -> Bool {
        try dbQueue.read { db in
            try DBConversation.fetchOne(db, key: id)?.isUnused ?? false
        }
    }

    @Test("an old empty self-only shell is hidden")
    func sweepsStrandedShell() async throws {
        let dbQueue = try makeDatabase()
        try await dbQueue.write { db in
            try seedInbox(db)
            try seedShell(db, id: "shell-1")
        }
        let swept = try await StrandedConversationSweeper.sweep(databaseWriter: dbQueue)
        #expect(swept == 1)
        #expect(try isUnused(dbQueue, "shell-1"))
    }

    @Test("update-type messages do not protect a shell")
    func sweepsShellWithOnlyMetadataCommits() async throws {
        let dbQueue = try makeDatabase()
        try await dbQueue.write { db in
            try seedInbox(db)
            try seedShell(db, id: "shell-1")
            try seedMessage(db, conversationId: "shell-1", id: "m-1", contentType: .update)
        }
        #expect(try await StrandedConversationSweeper.sweep(databaseWriter: dbQueue) == 1)
        #expect(try isUnused(dbQueue, "shell-1"))
    }

    @Test("any real message keeps the conversation")
    func keepsConversationWithContent() async throws {
        let dbQueue = try makeDatabase()
        try await dbQueue.write { db in
            try seedInbox(db)
            try seedShell(db, id: "kept-1")
            try seedMessage(db, conversationId: "kept-1", id: "m-1", contentType: .text)
        }
        #expect(try await StrandedConversationSweeper.sweep(databaseWriter: dbQueue) == 0)
        #expect(try isUnused(dbQueue, "kept-1") == false)
    }

    @Test("a name keeps the conversation")
    func keepsNamedConversation() async throws {
        let dbQueue = try makeDatabase()
        try await dbQueue.write { db in
            try seedInbox(db)
            try seedConversation(
                db, id: "kept-1", createdAt: Self.oldDate, name: "Weekend plans",
                creatorId: Self.selfInbox, isAgentDm: false, otherMemberInboxId: nil,
                isPinned: false, hasSharedInvite: false, hasHadOtherMembers: false
            )
        }
        #expect(try await StrandedConversationSweeper.sweep(databaseWriter: dbQueue) == 0)
        #expect(try isUnused(dbQueue, "kept-1") == false)
    }

    @Test("another member keeps the conversation")
    func keepsConversationWithOtherMember() async throws {
        let dbQueue = try makeDatabase()
        try await dbQueue.write { db in
            try seedInbox(db)
            try seedConversation(
                db, id: "kept-1", createdAt: Self.oldDate, name: nil,
                creatorId: Self.selfInbox, isAgentDm: false, otherMemberInboxId: Self.otherInbox,
                isPinned: false, hasSharedInvite: false, hasHadOtherMembers: false
            )
        }
        #expect(try await StrandedConversationSweeper.sweep(databaseWriter: dbQueue) == 0)
        #expect(try isUnused(dbQueue, "kept-1") == false)
    }

    @Test("recent shells are left for a later sweep")
    func keepsRecentShell() async throws {
        let dbQueue = try makeDatabase()
        try await dbQueue.write { db in
            try seedInbox(db)
            try seedShell(db, id: "kept-1", createdAt: Date())
        }
        #expect(try await StrandedConversationSweeper.sweep(databaseWriter: dbQueue) == 0)
        #expect(try isUnused(dbQueue, "kept-1") == false)
    }

    @Test("pin, shared invite, or past members keep the conversation")
    func keepsTouchedLocalState() async throws {
        let dbQueue = try makeDatabase()
        try await dbQueue.write { db in
            try seedInbox(db)
            try seedConversation(
                db, id: "kept-pinned", createdAt: Self.oldDate, name: nil,
                creatorId: Self.selfInbox, isAgentDm: false, otherMemberInboxId: nil,
                isPinned: true, hasSharedInvite: false, hasHadOtherMembers: false
            )
            try seedConversation(
                db, id: "kept-shared", createdAt: Self.oldDate, name: nil,
                creatorId: Self.selfInbox, isAgentDm: false, otherMemberInboxId: nil,
                isPinned: false, hasSharedInvite: true, hasHadOtherMembers: false
            )
            try seedConversation(
                db, id: "kept-had-members", createdAt: Self.oldDate, name: nil,
                creatorId: Self.selfInbox, isAgentDm: false, otherMemberInboxId: nil,
                isPinned: false, hasSharedInvite: false, hasHadOtherMembers: true
            )
        }
        #expect(try await StrandedConversationSweeper.sweep(databaseWriter: dbQueue) == 0)
        #expect(try isUnused(dbQueue, "kept-pinned") == false)
        #expect(try isUnused(dbQueue, "kept-shared") == false)
        #expect(try isUnused(dbQueue, "kept-had-members") == false)
    }

    @Test("conversations created by someone else are never touched")
    func keepsForeignCreator() async throws {
        let dbQueue = try makeDatabase()
        try await dbQueue.write { db in
            try seedInbox(db)
            try DBMember(inboxId: Self.otherInbox).save(db, onConflict: .ignore)
            try seedConversation(
                db, id: "kept-1", createdAt: Self.oldDate, name: nil,
                creatorId: Self.otherInbox, isAgentDm: false, otherMemberInboxId: nil,
                isPinned: false, hasSharedInvite: false, hasHadOtherMembers: false
            )
        }
        #expect(try await StrandedConversationSweeper.sweep(databaseWriter: dbQueue) == 0)
        #expect(try isUnused(dbQueue, "kept-1") == false)
    }

    @Test("agent DM rows are out of scope")
    func skipsAgentDms() async throws {
        let dbQueue = try makeDatabase()
        try await dbQueue.write { db in
            try seedInbox(db)
            try seedConversation(
                db, id: "dm-1", createdAt: Self.oldDate, name: nil,
                creatorId: Self.selfInbox, isAgentDm: true, otherMemberInboxId: nil,
                isPinned: false, hasSharedInvite: false, hasHadOtherMembers: false
            )
        }
        #expect(try await StrandedConversationSweeper.sweep(databaseWriter: dbQueue) == 0)
        #expect(try isUnused(dbQueue, "dm-1") == false)
    }

}
