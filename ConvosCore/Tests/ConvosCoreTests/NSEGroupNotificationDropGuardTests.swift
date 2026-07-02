@testable import ConvosCore
import Foundation
import GRDB
import Testing

/// Coverage for `MessagingService.shouldDropGroupNotification` -- the NSE
/// second line of defense that suppresses a group push banner when the local
/// state says the user is no longer in the conversation. Closes the in-flight
/// push race (a push already sent before the backend unsubscribe landed) and
/// the removed-but-still-`.allowed` kick case the reconcile never drops.
@Suite("NSE group-notification drop guard", .serialized)
struct NSEGroupNotificationDropGuardTests {
    private static let currentInboxId: String = "inbox-current"
    private static let otherInboxId: String = "inbox-other"

    private static func seedConversation(
        db: Database,
        id: String,
        consent: Consent = .allowed,
        wasRemoved: Bool = false,
        currentIsMember: Bool = true
    ) throws {
        try DBMember(inboxId: currentInboxId).save(db, onConflict: .ignore)
        try DBMember(inboxId: otherInboxId).save(db, onConflict: .ignore)
        try DBInbox(
            inboxId: currentInboxId,
            clientId: "client-current",
            createdAt: Date()
        ).save(db, onConflict: .ignore)

        try DBConversation(
            id: id,
            clientConversationId: "client-\(id)",
            inviteTag: "tag-\(id)",
            creatorId: otherInboxId,
            kind: .group,
            consent: consent,
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
            conversationId: id,
            isPinned: false,
            isUnread: false,
            isUnreadUpdatedAt: Date(),
            isMuted: false,
            pinnedOrder: nil,
            hidesInviteCard: false,
            leftHostedInviteSession: false,
            wasRemoved: wasRemoved,
            hasHadOtherMembers: false,
            hasSharedInvite: false
        ).insert(db)

        var memberInboxIds: [String] = [otherInboxId]
        if currentIsMember {
            memberInboxIds.append(currentInboxId)
        }
        for inboxId in memberInboxIds {
            try DBConversationMember(
                conversationId: id,
                inboxId: inboxId,
                role: .member,
                consent: .allowed,
                createdAt: Date(),
                invitedByInboxId: nil
            ).insert(db)
        }
    }

    private static func shouldDrop(
        db: Database,
        id: String,
        consent: Consent
    ) throws -> Bool {
        try MessagingService.shouldDropGroupNotification(
            db: db,
            conversationId: id,
            consent: consent,
            currentInboxId: currentInboxId
        )
    }

    @Test("Renders for an active conversation the user is still in")
    func rendersForActiveMembership() throws {
        let dbManager = MockDatabaseManager.makeTestDatabase()
        let result = try dbManager.dbWriter.write { db -> Bool in
            try Self.seedConversation(db: db, id: "active")
            return try Self.shouldDrop(db: db, id: "active", consent: .allowed)
        }
        #expect(result == false)
    }

    @Test("Drops when the user left (consent denied)")
    func dropsWhenConsentDenied() throws {
        let dbManager = MockDatabaseManager.makeTestDatabase()
        let result = try dbManager.dbWriter.write { db -> Bool in
            try Self.seedConversation(db: db, id: "left", consent: .denied)
            return try Self.shouldDrop(db: db, id: "left", consent: .denied)
        }
        #expect(result == true)
    }

    @Test("Drops when the user was removed (wasRemoved), even with consent still allowed")
    func dropsWhenRemovedWithConsentAllowed() throws {
        let dbManager = MockDatabaseManager.makeTestDatabase()
        // The kick path sets wasRemoved but leaves consent untouched -- this is
        // the case the reconcile desired set never diffs out, so the guard must
        // catch it on the consent-allowed value the row still carries.
        let result = try dbManager.dbWriter.write { db -> Bool in
            try Self.seedConversation(db: db, id: "kicked", consent: .allowed, wasRemoved: true)
            return try Self.shouldDrop(db: db, id: "kicked", consent: .allowed)
        }
        #expect(result == true)
    }

    @Test("Drops when the current inbox is absent from the member list")
    func dropsWhenNotAMember() throws {
        let dbManager = MockDatabaseManager.makeTestDatabase()
        // Membership pruned after removal (XMTP no longer lists the local inbox)
        // but wasRemoved not yet persisted -- the membership check still drops.
        let result = try dbManager.dbWriter.write { db -> Bool in
            try Self.seedConversation(db: db, id: "not-member", consent: .allowed, currentIsMember: false)
            return try Self.shouldDrop(db: db, id: "not-member", consent: .allowed)
        }
        #expect(result == true)
    }
}
