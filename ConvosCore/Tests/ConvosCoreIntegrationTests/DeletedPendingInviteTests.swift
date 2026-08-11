@testable import ConvosCore
import Foundation
import GRDB
import Testing
import XMTPiOS

/// Coverage for the denial carry-forward that keeps a deleted
/// pending-invite ("verifying") conversation deleted once the invite is
/// approved. Deleting a draft can only flip the local row to `.denied`
/// (no XMTP group exists yet to deny). When the real group later arrives
/// it replaces that row by invite-tag match and must inherit the denial
/// instead of resurrecting the conversation in the list.
@Suite("Deleted pending-invite denial carry-forward", .serialized)
struct DeletedPendingInviteTests {
    private enum TestError: Error {
        case missingClients
    }

    @Test("persist() carries .denied from the replaced draft row onto the arriving group")
    func persistInheritsDenialFromDeletedDraft() async throws {
        let dbManager = MockDatabaseManager.makeTestDatabase()
        let inviteTag = "tag-denied-draft"
        let draftId = "draft-deleted-1"
        try seedConversation(in: dbManager.dbWriter, id: draftId, inviteTag: inviteTag, consent: .denied)

        let writer = ConversationWriter(
            identityStore: MockKeychainIdentityStore(),
            databaseWriter: dbManager.dbWriter,
            messageWriter: MockIncomingMessageWriter()
        )

        let incoming = makeDBConversation(id: "real-group-1", inviteTag: inviteTag, consent: .allowed)
        let prepared = ConversationWriter.PreparedConversation(
            dbConversation: incoming,
            dbMembers: [],
            memberProfiles: []
        )
        let saveResult = try await dbManager.dbWriter.write { db in
            try writer.persist(prepared, in: db)
        }
        // The inherited denial is surfaced so the caller pushes it into the
        // XMTP consent state (the prepare-time check missed this delete).
        #expect(saveResult.deniedConsentCarriedForward)

        let real = try await dbManager.dbReader.read { db in
            try DBConversation.fetchOne(db, id: "real-group-1")
        }
        #expect(real?.consent == .denied)

        let draft = try await dbManager.dbReader.read { db in
            try DBConversation.fetchOne(db, id: draftId)
        }
        #expect(draft == nil)
    }

    @Test("persist() keeps the incoming consent when the matching draft was not deleted")
    func persistKeepsConsentForLiveDraft() async throws {
        let dbManager = MockDatabaseManager.makeTestDatabase()
        let inviteTag = "tag-live-draft"
        let draftId = "draft-live-1"
        try seedConversation(in: dbManager.dbWriter, id: draftId, inviteTag: inviteTag, consent: .allowed)

        let writer = ConversationWriter(
            identityStore: MockKeychainIdentityStore(),
            databaseWriter: dbManager.dbWriter,
            messageWriter: MockIncomingMessageWriter()
        )

        let incoming = makeDBConversation(id: "real-group-2", inviteTag: inviteTag, consent: .allowed)
        let prepared = ConversationWriter.PreparedConversation(
            dbConversation: incoming,
            dbMembers: [],
            memberProfiles: []
        )
        let saveResult = try await dbManager.dbWriter.write { db in
            try writer.persist(prepared, in: db)
        }
        #expect(!saveResult.deniedConsentCarriedForward)

        let real = try await dbManager.dbReader.read { db in
            try DBConversation.fetchOne(db, id: "real-group-2")
        }
        #expect(real?.consent == .allowed)
    }

    @Test("store() denies the arriving XMTP group when its invite tag matches a deleted local conversation")
    func storeDeniesArrivingGroupMatchingDeletedInvite() async throws {
        let fixtures = TestFixtures()
        try await fixtures.createTestClients()

        guard let clientA = fixtures.clientA as? Client,
              let clientB = fixtures.clientB,
              let clientIdA = fixtures.clientIdA else {
            throw TestError.missingClients
        }

        let inboxIdA = clientA.inboxID
        try await fixtures.databaseManager.dbWriter.write { db in
            try DBInbox(inboxId: inboxIdA, clientId: clientIdA, createdAt: Date()).insert(db)
        }

        let group = try await clientA.conversations.newGroup(
            with: [clientB.inboxId],
            name: "Test Group",
            imageUrl: "",
            description: ""
        )
        try await group.ensureInviteTag()
        let inviteTag = try group.inviteTag
        #expect(!inviteTag.isEmpty)

        // The user deleted the conversation while it was still "verifying":
        // only the local draft row carries the denial.
        let draftId = "draft-deleted-2"
        try seedConversation(
            in: fixtures.databaseManager.dbWriter,
            id: draftId,
            inviteTag: inviteTag,
            consent: .denied
        )

        let writer = ConversationWriter(
            identityStore: fixtures.identityStore,
            databaseWriter: fixtures.databaseManager.dbWriter,
            messageWriter: MockIncomingMessageWriter()
        )
        _ = try await writer.store(conversation: group, inboxId: inboxIdA)

        let groupId = group.id
        let stored = try await fixtures.databaseManager.dbReader.read { db in
            try DBConversation.fetchOne(db, id: groupId)
        }
        #expect(stored?.consent == .denied)

        // The denial must reach the XMTP consent state too, so inbound
        // stream filtering and later syncs keep agreeing the conversation
        // stays deleted.
        #expect(try group.consentState() == .denied)

        let draft = try await fixtures.databaseManager.dbReader.read { db in
            try DBConversation.fetchOne(db, id: draftId)
        }
        #expect(draft == nil)

        try? await fixtures.cleanup()
    }
}

// MARK: - Helpers

private func seedConversation(
    in writer: any DatabaseWriter,
    id: String,
    inviteTag: String,
    consent: Consent
) throws {
    try writer.write { db in
        try DBMember(inboxId: "inbox-creator").save(db)
        try DBConversation(
            id: id,
            clientConversationId: id,
            inviteTag: inviteTag,
            creatorId: "inbox-creator",
            kind: .group,
            consent: consent,
            createdAt: Date(),
            name: "Verifying",
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
        ).insert(db)
    }
}

private func makeDBConversation(
    id: String,
    inviteTag: String,
    consent: Consent
) -> DBConversation {
    DBConversation(
        id: id,
        clientConversationId: id,
        inviteTag: inviteTag,
        creatorId: "inbox-creator",
        kind: .group,
        consent: consent,
        createdAt: Date(),
        name: "Arrived",
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
    )
}
