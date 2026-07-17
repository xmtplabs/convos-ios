@testable import ConvosCore
import Combine
import Foundation
import GRDB
import Testing

/// Determines whether the conversation-list `ValueObservation` re-fires when a
/// member's canonical `profileAvatar` changes.
///
/// The list joins each member's avatar through the `profileAvatarLatest` *view*
/// (`DBConversationMember.avatarSlot`), fetched via an `.including(all:)`
/// prefetch. Whether GRDB's region tracking reaches the underlying `profileAvatar`
/// table through that view is the open question behind the "stale cluster until
/// you open the conversation" bug:
///
/// - If `reEmitsOnMemberProfileAvatarWrite` passes, the data layer is already
///   reactive and the stale-cluster bug is a UI cell-reload problem (fix the
///   list/diffable-data-source, not the observation).
/// - If it fails while the `reEmitsOnConversationChange` control passes, the
///   observation is not tracking `profileAvatar` through the view and needs an
///   explicit tracked region.
@Suite("Conversation list observation - profileAvatar reactivity", .serialized)
struct ConversationsRepositoryAvatarObservationTests {
    private let salt = Data(repeating: 1, count: 32)
    private let nonce = Data(repeating: 2, count: 12)
    private let key = Data(repeating: 3, count: 32)

    private func seedGroup(_ db: Database) throws {
        try DBMember(inboxId: "me").save(db, onConflict: .ignore)
        try DBInbox(inboxId: "me", clientId: "client-me", createdAt: Date()).save(db, onConflict: .ignore)
        try DBMember(inboxId: "alice").save(db, onConflict: .ignore)

        try DBConversation(
            id: "c1",
            clientConversationId: "client-c1",
            inviteTag: "tag-c1",
            creatorId: "me",
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
            hasHadVerifiedAgent: false
        ).insert(db)

        try ConversationLocalState(
            conversationId: "c1",
            isPinned: false,
            isUnread: false,
            isUnreadUpdatedAt: Date(),
            isMuted: false,
            pinnedOrder: nil,
            hidesInviteCard: false,
            leftHostedInviteSession: false,
            wasRemoved: false,
            hasHadOtherMembers: false,
            hasSharedInvite: false
        ).insert(db)

        for (inboxId, role) in [("me", MemberRole.superAdmin), ("alice", MemberRole.member)] {
            try DBConversationMember(
                conversationId: "c1",
                inboxId: inboxId,
                role: role,
                consent: .allowed,
                createdAt: Date(),
                invitedByInboxId: nil
            ).insert(db)
        }
        try DBProfile(
            inboxId: "alice", name: "Alice", profileSource: .profileUpdate,
            updatedAt: Date(timeIntervalSince1970: 1)
        ).save(db)
    }

    @Test("re-emits when a member's profileAvatar is written (through the profileAvatarLatest view)")
    func reEmitsOnMemberProfileAvatarWrite() async throws {
        let dbManager = MockDatabaseManager.makeTestDatabase()
        let writer = dbManager.dbWriter
        try await writer.write { db in try self.seedGroup(db) }

        let counter = EmissionCounter()
        let repo = ConversationsRepository(dbReader: writer, consent: [.allowed])
        let cancellable = repo.conversationsPublisher.sink { _ in counter.increment() }
        defer { cancellable.cancel() }

        try await Task.sleep(nanoseconds: 300_000_000)
        let afterInitial = counter.count
        #expect(afterInitial >= 1, "Observation should deliver an initial value")

        // Simulate Alice updating her photo: a new canonical avatar row.
        try await writer.write { db in
            try DBProfileAvatar(
                inboxId: "alice", conversationId: "c1",
                url: "https://example.com/alice-new.bin",
                salt: self.salt, nonce: self.nonce, encryptionKey: self.key,
                profileSource: .profileUpdate, updatedAt: Date()
            ).save(db)
        }

        try await Task.sleep(nanoseconds: 800_000_000)
        #expect(
            counter.count > afterInitial,
            "Expected the conversation-list observation to re-emit when a member's profileAvatar changed"
        )
    }

    @Test("control: re-emits when the conversation row itself changes")
    func reEmitsOnConversationChange() async throws {
        let dbManager = MockDatabaseManager.makeTestDatabase()
        let writer = dbManager.dbWriter
        try await writer.write { db in try self.seedGroup(db) }

        let counter = EmissionCounter()
        let repo = ConversationsRepository(dbReader: writer, consent: [.allowed])
        let cancellable = repo.conversationsPublisher.sink { _ in counter.increment() }
        defer { cancellable.cancel() }

        try await Task.sleep(nanoseconds: 300_000_000)
        let afterInitial = counter.count
        #expect(afterInitial >= 1, "Observation should deliver an initial value")

        try await writer.write { db in
            guard let conversation = try DBConversation.fetchOne(db, key: "c1") else { return }
            try conversation.with(name: "Renamed").save(db)
        }

        try await Task.sleep(nanoseconds: 800_000_000)
        #expect(
            counter.count > afterInitial,
            "Control failed: the observation did not re-emit even for a direct conversation change"
        )
    }
}

private final class EmissionCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0
    func increment() {
        lock.lock()
        value += 1
        lock.unlock()
    }
    var count: Int {
        lock.lock()
        defer { lock.unlock() }
        return value
    }
}
