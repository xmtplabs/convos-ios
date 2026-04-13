import ConvosProfiles
import Foundation
import GRDB
@preconcurrency import XMTPiOS

protocol ConvoRequestManagerProtocol: Sendable {
    func processConvoRequest(message: DecodedMessage, client: AnyClientProvider) async -> Bool
}

final class ConvoRequestManager: ConvoRequestManagerProtocol, @unchecked Sendable {
    private let databaseReader: any DatabaseReader
    private let databaseWriter: any DatabaseWriter
    private let identityStore: any KeychainIdentityStoreProtocol

    init(
        databaseReader: any DatabaseReader,
        databaseWriter: any DatabaseWriter,
        identityStore: any KeychainIdentityStoreProtocol
    ) {
        self.databaseReader = databaseReader
        self.databaseWriter = databaseWriter
        self.identityStore = identityStore
    }

    func processConvoRequest(message: DecodedMessage, client: AnyClientProvider) async -> Bool {
        guard let convoRequest = try? ConvoRequestCodec().decode(content: message.encodedContent) else {
            return false
        }

        let senderInboxId = message.senderInboxId
        let originConversationId = convoRequest.originConversationID

        guard senderInboxId != client.inboxId else {
            Log.debug("Ignoring own convo request")
            return true
        }

        Log.info("Received convo request from \(senderInboxId.prefix(8)) via group \(originConversationId.prefix(8))")

        guard await validateRequest(
            senderInboxId: senderInboxId,
            originConversationId: originConversationId,
            currentInboxId: client.inboxId
        ) else {
            Log.info("Convo request rejected: consent check failed")
            return true
        }

        if convoRequest.hasInviteSlug {
            Log.info("Convo request is a group spinoff (phase 2), ignoring for now")
            return true
        }

        await createDMConversation(
            request: convoRequest,
            senderInboxId: senderInboxId,
            client: client
        )

        return true
    }

    private func validateRequest(
        senderInboxId: String,
        originConversationId: String,
        currentInboxId: String
    ) async -> Bool {
        do {
            return try await databaseReader.read { db in
                guard let conversation = try DBConversation.fetchOne(db, key: originConversationId) else {
                    Log.warning("Convo request: origin conversation \(originConversationId.prefix(8)) not found")
                    return false
                }

                let senderIsMember = try DBConversationMember
                    .filter(DBConversationMember.Columns.conversationId == originConversationId)
                    .filter(DBConversationMember.Columns.inboxId == senderInboxId)
                    .fetchCount(db) > 0

                guard senderIsMember else {
                    Log.warning("Convo request: sender \(senderInboxId.prefix(8)) not a member of origin conversation")
                    return false
                }

                let myProfile = try DBMemberProfile.fetchOne(
                    db,
                    conversationId: originConversationId,
                    inboxId: currentInboxId
                )

                let allowsDMs = myProfile?.metadata?.allowsDMs ?? false
                guard allowsDMs else {
                    Log.info("Convo request: DMs not enabled for origin conversation \(originConversationId.prefix(8))")
                    return false
                }

                return true
            }
        } catch {
            Log.error("Convo request validation failed: \(error.localizedDescription)")
            return false
        }
    }

    private func createDMConversation(
        request: ConvoRequest,
        senderInboxId: String,
        client: AnyClientProvider
    ) async {
        do {
            let conversationId = try await client.newConversation(
                with: [request.newInboxID],
                name: "",
                description: "",
                imageUrl: ""
            )

            Log.info("Created DM conversation \(conversationId.prefix(8)) with \(senderInboxId.prefix(8))")

            guard let conversation = try await client.conversationsProvider.findConversation(conversationId: conversationId),
                  case .group(let group) = conversation else {
                Log.error("Failed to find newly created DM conversation")
                return
            }

            try await group.updateAddMemberPermission(newPermissionOption: PermissionOption.deny)
            Log.debug("Locked DM conversation (addMember = deny)")

            let messageWriter = IncomingMessageWriter(databaseWriter: databaseWriter)
            let conversationWriter = ConversationWriter(
                identityStore: identityStore,
                databaseWriter: databaseWriter,
                messageWriter: messageWriter
            )
            let dbConversation = try await conversationWriter.store(
                conversation: group,
                inboxId: client.inboxId
            )

            try await databaseWriter.write { db in
                let updated = dbConversation.with(kind: .dm)
                try updated.update(db)
            }

            let localStateWriter = ConversationLocalStateWriter(databaseWriter: databaseWriter)
            try await localStateWriter.setUnread(true, for: dbConversation.id)

            let dmLinksWriter = DMLinksWriter(databaseWriter: databaseWriter)
            try await dmLinksWriter.store(
                originConversationId: request.originConversationID,
                memberInboxId: senderInboxId,
                dmConversationId: conversationId,
                convoTag: request.convoTag
            )

            if request.hasSenderProfileSnapshot,
               let senderProfile = request.senderProfileSnapshot.findProfile(inboxId: senderInboxId) {
                try await applySeededProfile(
                    senderProfile,
                    inboxId: senderInboxId,
                    conversationId: conversationId,
                    fallbackEncryptionKey: try? group.imageEncryptionKey
                )
            }

            try await seedCurrentUserProfile(
                from: request.originConversationID,
                to: conversationId,
                currentInboxId: client.inboxId,
                group: group
            )

            Log.info("DM conversation \(conversationId.prefix(8)) stored and marked as unread")
        } catch {
            Log.error("Failed to create DM conversation: \(error.localizedDescription)")
        }
    }

    private func applySeededProfile(
        _ memberProfile: MemberProfile,
        inboxId: String,
        conversationId: String,
        fallbackEncryptionKey: Data?
    ) async throws {
        try await databaseWriter.write { db in
            let member = DBMember(inboxId: inboxId)
            try member.save(db)

            var profile = try DBMemberProfile.fetchOne(db, conversationId: conversationId, inboxId: inboxId)
                ?? DBMemberProfile(conversationId: conversationId, inboxId: inboxId, name: nil, avatar: nil)

            profile = profile.with(name: memberProfile.hasName ? memberProfile.name : nil)

            if memberProfile.hasEncryptedImage, memberProfile.encryptedImage.isValid {
                let image = memberProfile.encryptedImage
                profile = profile.with(
                    avatar: image.url,
                    salt: image.salt,
                    nonce: image.nonce,
                    key: profile.avatarKey ?? fallbackEncryptionKey
                )
            }

            if !memberProfile.metadata.isEmpty {
                profile = profile.with(metadata: memberProfile.profileMetadata)
            }

            try profile.save(db)
        }
    }

    private func seedCurrentUserProfile(
        from originConversationId: String,
        to conversationId: String,
        currentInboxId: String,
        group: XMTPiOS.Group
    ) async throws {
        let originProfile = try await databaseReader.read { db in
            try DBMemberProfile.fetchOne(db, conversationId: originConversationId, inboxId: currentInboxId)
        }
        guard let originProfile else { return }

        let seededProfile = try await databaseWriter.write { db in
            let member = DBMember(inboxId: currentInboxId)
            try member.save(db)
            var profile = try DBMemberProfile.fetchOne(db, conversationId: conversationId, inboxId: currentInboxId)
                ?? DBMemberProfile(conversationId: conversationId, inboxId: currentInboxId, name: nil, avatar: nil)
            profile = profile.with(name: originProfile.name)
            if let avatar = originProfile.avatar,
               let salt = originProfile.avatarSalt,
               let nonce = originProfile.avatarNonce,
               salt.count == 32,
               nonce.count == 12 {
                profile = profile.with(avatar: avatar, salt: salt, nonce: nonce, key: originProfile.avatarKey)
            }
            if let metadata = originProfile.metadata {
                profile = profile.with(metadata: metadata)
            }
            try profile.save(db)
            return profile
        }

        do {
            try await group.updateProfile(seededProfile)
        } catch {
            Log.warning("Failed to seed current user profile to appData (best-effort): \(error.localizedDescription)")
        }

        var update = ProfileUpdate()
        if let name = seededProfile.name {
            update.name = name
        }
        if let encryptedRef = seededProfile.encryptedImageRef {
            update.encryptedImage = EncryptedProfileImageRef(encryptedRef)
        }
        if let metadata = seededProfile.metadata, !metadata.isEmpty {
            update.metadata = metadata.asProtoMap
        }
        let encoded = try ProfileUpdateCodec().encode(content: update)
        _ = try await group.send(encodedContent: encoded)
    }
}
