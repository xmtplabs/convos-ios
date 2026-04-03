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
            let conversationId = try await client.conversationsProvider.newConversation(
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

            try await group.updateGroupMemberPermission(
                permissionOption: .denyAll,
                permissionType: .addMember
            )
            Log.debug("Locked DM conversation (addMember = denyAll)")

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
                var localState = try ConversationLocalState
                    .filter(ConversationLocalState.Columns.conversationId == dbConversation.id)
                    .fetchOne(db)
                    ?? ConversationLocalState(
                        conversationId: dbConversation.id,
                        isPinned: false,
                        isUnread: false,
                        isUnreadUpdatedAt: Date(),
                        isMuted: false,
                        pinnedOrder: nil
                    )
                localState = localState.with(isUnread: true)
                try localState.save(db)
            }

            Log.info("DM conversation \(conversationId.prefix(8)) stored and marked as unread")
        } catch {
            Log.error("Failed to create DM conversation: \(error.localizedDescription)")
        }
    }
}
