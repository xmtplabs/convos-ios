import ConvosInvites
import ConvosMetrics
import Foundation
import GRDB

protocol InviteWriterProtocol {
    func generate(for conversation: DBConversation, expiresAt: Date?, expiresAfterUse: Bool) async throws -> Invite
    func update(for conversationId: String) async throws -> Invite
    func delete(for conversationId: String) async throws
}

enum InviteWriterError: Error {
    case failedEncodingInvitePayload
    case conversationNotFound
    case inviteNotFound
}

class InviteWriter: InviteWriterProtocol {
    private let identityStore: any KeychainIdentityStoreProtocol
    private let databaseWriter: any DatabaseWriter
    private let coreActions: any CoreActions

    init(identityStore: any KeychainIdentityStoreProtocol,
         databaseWriter: any DatabaseWriter,
         coreActions: any CoreActions) {
        self.identityStore = identityStore
        self.databaseWriter = databaseWriter
        self.coreActions = coreActions
    }

    func generate(
        for conversation: DBConversation,
        expiresAt: Date? = nil,
        expiresAfterUse: Bool = false
    ) async throws -> Invite {
        do {
            guard let identity = try await identityStore.load() else {
                throw KeychainIdentityStoreError.identityNotFound("No identity available to sign invite for conversation \(conversation.id)")
            }
            let currentInboxId = identity.inboxId

            if let existingInvite = try? await self.databaseWriter.read({ db in
                try? DBInvite
                    .filter(DBInvite.Columns.conversationId == conversation.id)
                    .filter(DBInvite.Columns.creatorInboxId == currentInboxId)
                    .fetchOne(db)
            }) {
                if inviteTagMatches(slug: existingInvite.urlSlug, tag: conversation.inviteTag) {
                    return existingInvite.hydrateInvite()
                }
                try await delete(for: conversation.id)
                Log.info("Invite tag changed for conversation \(conversation.id), re-creating invite")
            }

            let privateKey: Data = identity.keys.privateKey.secp256K1.bytes
            let urlSlug = try SignedInvite.slug(
                for: conversation,
                creatorInboxId: currentInboxId,
                expiresAt: expiresAt,
                expiresAfterUse: expiresAfterUse,
                privateKey: privateKey
            )

            let dbInvite = DBInvite(
                creatorInboxId: currentInboxId,
                conversationId: conversation.id,
                urlSlug: urlSlug,
                expiresAt: expiresAt,
                expiresAfterUse: expiresAfterUse
            )
            let (memberCount, hasAssistant): (Int, Bool) = try await databaseWriter.write { db in
                try DBMember(inboxId: currentInboxId).save(db, onConflict: .ignore)
                try DBConversationMember(
                    conversationId: conversation.id,
                    inboxId: currentInboxId,
                    role: .member,
                    consent: .allowed,
                    createdAt: Date(),
                    invitedByInboxId: nil
                )
                .insert(db, onConflict: .ignore)
                let memberProfile = DBMemberProfile(
                    conversationId: conversation.id,
                    inboxId: currentInboxId,
                    name: nil,
                    avatar: nil
                )
                try? memberProfile.insert(db, onConflict: .ignore)
                try dbInvite.save(db)
                let count: Int = try DBConversationMember
                    .filter(DBConversationMember.Columns.conversationId == conversation.id)
                    .fetchCount(db)
                let agentRow: DBMemberProfile? = try DBMemberProfile
                    .filter(DBMemberProfile.Columns.conversationId == conversation.id)
                    .filter(DBMemberProfile.Columns.memberKind != nil)
                    .fetchOne(db)
                return (count, agentRow?.isAgent ?? false)
            }
            let actions: any CoreActions = coreActions
            Task {
                await actions.invitedToConversation(
                    memberCount: memberCount,
                    hasAssistant: hasAssistant,
                    isSuccess: true
                )
            }
            return dbInvite.hydrateInvite()
        } catch {
            Log.warning("Failed to create invite for conversation \(conversation.id), will retry on next sync: \(error)")
            reportInviteCreationFailed()
            throw error
        }
    }

    /// A conversation with no invite cannot be joined at all, so a mint that
    /// fails is the earliest point the invite funnel can break. Every throwing
    /// exit from `generate` reports here - the identity load and the preflight
    /// delete included, which is why they sit inside the instrumented `do`.
    /// All of it previously reached nothing but a local warning.
    ///
    /// `memberCount` / `hasAssistant` report 0 / false because the counts are
    /// read from the write that failed; `isSuccess` is what separates these
    /// from real samples.
    private func reportInviteCreationFailed() {
        let actions: any CoreActions = coreActions
        Task {
            await actions.invitedToConversation(
                memberCount: 0,
                hasAssistant: false,
                isSuccess: false
            )
        }
    }

    func update(for conversationId: String) async throws -> Invite {
        guard let conversation = try await databaseWriter.read({ db in
            try DBConversation
                .fetchOne(db, key: conversationId)
        }) else {
            throw InviteWriterError.conversationNotFound
        }
        guard let identity = try await identityStore.load() else {
            throw KeychainIdentityStoreError.identityNotFound("No identity available to update invite for conversation \(conversation.id)")
        }
        let currentInboxId = identity.inboxId
        let invite = try await databaseWriter.read { db in
            try DBInvite
                .filter(DBInvite.Columns.conversationId == conversation.id)
                .filter(DBInvite.Columns.creatorInboxId == currentInboxId)
                .fetchOne(db)
        }
        guard let invite else { throw InviteWriterError.inviteNotFound }
        let privateKey: Data = identity.keys.privateKey.secp256K1.bytes
        let urlSlug = try SignedInvite.slug(
            for: conversation,
            creatorInboxId: currentInboxId,
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

    func delete(for conversationId: String) async throws {
        _ = try await databaseWriter.write { db in
            try DBInvite
                .filter(DBInvite.Columns.conversationId == conversationId)
                .deleteAll(db)
        }
        Log.info("Deleted invite for conversation: \(conversationId)")
    }

    private func inviteTagMatches(slug: String, tag: String) -> Bool {
        guard let signedInvite = try? SignedInvite.fromURLSafeSlug(slug) else {
            return false
        }
        return signedInvite.invitePayload.tag == tag
    }
}
