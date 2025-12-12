import Foundation
import GRDB

public protocol InviteWriterProtocol {
    func generate(for conversation: DBConversation, expiresAt: Date?, expiresAfterUse: Bool) async throws -> Invite
    func update(for conversationId: String, name: String?, description: String?, imageURL: String?) async throws -> Invite
}

enum InviteWriterError: Error {
    case failedEncodingInvitePayload
    case conversationNotFound
    case inviteNotFound
}

class InviteWriter: InviteWriterProtocol {
    private let identityStore: any KeychainIdentityStoreProtocol
    private let databaseWriter: any DatabaseWriter

    init(identityStore: any KeychainIdentityStoreProtocol,
         databaseWriter: any DatabaseWriter) {
        self.identityStore = identityStore
        self.databaseWriter = databaseWriter
    }

    func generate(
        for conversation: DBConversation,
        expiresAt: Date? = nil,
        expiresAfterUse: Bool = false) async throws -> Invite {
        let existingInvite = try? await self.databaseWriter.read { db in
            try? DBInvite
                .filter(DBInvite.Columns.conversationId == conversation.id)
                .filter(DBInvite.Columns.creatorInboxId == conversation.inboxId)
                .fetchOne(db)
        }
        if let existingInvite {
            Log.info("Existing invite found for conversation: \(conversation.id), \(existingInvite)")
            return existingInvite.hydrateInvite()
        }

        let identity = try await identityStore.identity(for: conversation.inboxId)
        let privateKey: Data = identity.keys.privateKey.secp256K1.bytes
        let urlSlug = try SignedInvite.slug(
            for: conversation,
            expiresAt: expiresAt,
            expiresAfterUse: expiresAfterUse,
            privateKey: privateKey
        )
        Log.info("Generated URL slug: \(urlSlug)")

        let dbInvite = DBInvite(
            creatorInboxId: conversation.inboxId,
            conversationId: conversation.id,
            urlSlug: urlSlug,
            expiresAt: expiresAt,
            expiresAfterUse: expiresAfterUse
        )
        try await databaseWriter.write { db in
            try DBMember(inboxId: conversation.inboxId).save(db, onConflict: .ignore)
            try DBConversationMember(
                conversationId: conversation.id,
                inboxId: conversation.inboxId,
                role: .member,
                consent: .allowed,
                createdAt: Date()
            )
            .save(db, onConflict: .ignore)
            let memberProfile = DBMemberProfile(
                conversationId: conversation.id,
                inboxId: conversation.inboxId,
                name: nil,
                avatar: nil
            )
            try? memberProfile.insert(db, onConflict: .ignore)
            try dbInvite.save(db)
        }
        return dbInvite.hydrateInvite()
    }

    func update(
        for conversationId: String,
        name: String?,
        description: String?,
        imageURL: String?
    ) async throws -> Invite {
        guard let conversation = try await databaseWriter.read({ db in
            try DBConversation
                .fetchOne(db, key: conversationId)
        }) else {
            throw InviteWriterError.conversationNotFound
        }
        let invite = try await databaseWriter.read { db in
            try DBInvite
                .filter(DBInvite.Columns.conversationId == conversation.id)
                .filter(DBInvite.Columns.creatorInboxId == conversation.inboxId)
                .fetchOne(db)
        }
        guard let invite else { throw InviteWriterError.inviteNotFound }
        let identity = try await identityStore.identity(for: conversation.inboxId)
        let privateKey: Data = identity.keys.privateKey.secp256K1.bytes
        let urlSlug = try SignedInvite.slug(
            for: conversation,
            expiresAt: invite.expiresAt,
            expiresAfterUse: invite.expiresAfterUse,
            privateKey: privateKey
        )
        let updatedInvite = invite
            .with(urlSlug: urlSlug)
        try await databaseWriter.write { db in
            try updatedInvite.save(db)
        }
        return updatedInvite.hydrateInvite()
    }
}
