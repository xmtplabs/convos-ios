import ConvosInvites
import Foundation
@preconcurrency import XMTPiOS

public struct JoinRequestResult: Sendable {
    public let conversationId: String
    public let conversationName: String?
    public let joinerInboxId: String
}

protocol InviteJoinRequestsManagerProtocol: Sendable {
    func processJoinRequest(
        message: XMTPiOS.DecodedMessage,
        client: AnyClientProvider
    ) async -> JoinRequestResult?
    func processJoinRequests(
        since: Date?,
        client: AnyClientProvider
    ) async -> [JoinRequestResult]
    func hasOutgoingJoinRequest(
        for conversation: XMTPiOS.Group,
        client: AnyClientProvider
    ) async throws -> Bool
}

/// Bridges ConvosInvites' join request processing with ConvosCore's client
/// provider abstraction. All crypto validation (signature verification, token
/// decryption) is delegated to ConvosInvites types.
class InviteJoinRequestsManager: InviteJoinRequestsManagerProtocol, @unchecked Sendable {
    private let identityStore: any KeychainIdentityStoreProtocol
    private let tagStorage: any InviteTagStorageProtocol

    init(
        identityStore: any KeychainIdentityStoreProtocol,
        tagStorage: any InviteTagStorageProtocol = ProtobufInviteTagStorage()
    ) {
        self.identityStore = identityStore
        self.tagStorage = tagStorage
    }

    // MARK: - Single Message Processing

    func processJoinRequest(
        message: XMTPiOS.DecodedMessage,
        client: AnyClientProvider
    ) async -> JoinRequestResult? {
        let senderInboxId = message.senderInboxId

        guard senderInboxId != client.inboxId else { return nil }

        guard let text: String = try? message.content() else { return nil }

        guard let signedInvite = try? SignedInvite.fromURLSafeSlug(text) else { return nil }

        let tag = signedInvite.invitePayload.tag

        do {
            let result = try await validateAndProcess(
                signedInvite: signedInvite,
                joinerInboxId: senderInboxId,
                dmConversationId: message.conversationId,
                client: client
            )
            Log.info("Successfully added \(senderInboxId) to conversation \(result.conversationId)")
            QAEvent.emit(.invite, "member_accepted", [
                "conversation": result.conversationId,
                "member": senderInboxId,
            ])
            return result
        } catch JoinRequestError.expired,
                JoinRequestError.invalidSignature,
                JoinRequestError.invalidFormat,
                JoinRequestError.creatorMismatch {
            return nil
        } catch JoinRequestError.conversationExpired {
            await sendJoinErrorIfPossible(.conversationExpired, tag: tag, conversationId: message.conversationId, client: client)
            return nil
        } catch JoinRequestError.conversationNotFound {
            await sendJoinErrorIfPossible(.conversationExpired, tag: tag, conversationId: message.conversationId, client: client)
            return nil
        } catch {
            await sendJoinErrorIfPossible(.genericFailure, tag: tag, conversationId: message.conversationId, client: client)
            return nil
        }
    }

    // MARK: - Batch Processing

    func processJoinRequests(since: Date?, client: AnyClientProvider) async -> [JoinRequestResult] {
        var results: [JoinRequestResult] = []

        guard let dms = try? client.conversationsProvider.listDms(
            createdAfterNs: since?.nanosecondsSince1970,
            createdBeforeNs: nil,
            lastActivityBeforeNs: nil,
            lastActivityAfterNs: nil,
            limit: nil,
            consentStates: [.unknown],
            orderBy: .lastActivity
        ) else { return [] }

        for dm in dms {
            if let result = await processDm(dm, client: client) {
                results.append(result)
            }
        }

        return results
    }

    // MARK: - Outgoing Request Check

    func hasOutgoingJoinRequest(
        for conversation: XMTPiOS.Group,
        client: AnyClientProvider
    ) async throws -> Bool {
        let inviteTag: String
        do {
            inviteTag = try tagStorage.getInviteTag(for: conversation)
        } catch {
            return false
        }
        guard !inviteTag.isEmpty else { return false }

        let dms = try client.conversationsProvider.listDms(
            createdAfterNs: nil,
            createdBeforeNs: nil,
            lastActivityBeforeNs: nil,
            lastActivityAfterNs: nil,
            limit: nil,
            consentStates: [.allowed],
            orderBy: .lastActivity
        )

        for dm in dms {
            if let invite = await dm.lastMessageAsSignedInvite(sentBy: client.inboxId),
               invite.invitePayload.tag == inviteTag {
                return true
            }
        }

        return false
    }

    // MARK: - Core Validation

    private func validateAndProcess(
        signedInvite: SignedInvite,
        joinerInboxId: String,
        dmConversationId: String,
        client: AnyClientProvider
    ) async throws -> JoinRequestResult {
        guard !signedInvite.hasExpired else {
            throw JoinRequestError.expired
        }

        guard !signedInvite.conversationHasExpired else {
            throw JoinRequestError.conversationExpired
        }

        let creatorInboxId = signedInvite.invitePayload.creatorInboxIdString

        guard !creatorInboxId.isEmpty else {
            await blockDM(conversationId: dmConversationId, client: client)
            throw JoinRequestError.invalidFormat
        }

        guard creatorInboxId == client.inboxId else {
            await blockDM(conversationId: dmConversationId, client: client)
            throw JoinRequestError.creatorMismatch
        }

        let identity = try await identityStore.identity(for: creatorInboxId)
        let publicKey = identity.keys.privateKey.publicKey.secp256K1Uncompressed.bytes

        do {
            guard try signedInvite.verify(with: publicKey) else {
                await blockDM(conversationId: dmConversationId, client: client)
                throw JoinRequestError.invalidSignature
            }
        } catch let error as JoinRequestError {
            throw error
        } catch {
            await blockDM(conversationId: dmConversationId, client: client)
            throw JoinRequestError.invalidSignature
        }

        let privateKey: Data = identity.keys.privateKey.secp256K1.bytes
        let conversationId = try InviteToken.decrypt(
            tokenBytes: signedInvite.invitePayload.conversationToken,
            creatorInboxId: client.inboxId,
            privateKey: privateKey
        )

        guard let conversation = try await client.conversationsProvider.findConversation(
            conversationId: conversationId
        ), try conversation.consentState() == .allowed else {
            throw JoinRequestError.conversationNotFound(conversationId)
        }

        switch conversation {
        case .group(let group):
            try await group.add(members: [joinerInboxId])

            return JoinRequestResult(
                conversationId: group.id,
                conversationName: try? group.name(),
                joinerInboxId: joinerInboxId
            )
        case .dm:
            throw JoinRequestError.invalidFormat
        }
    }

    // MARK: - Helpers

    private func processDm(_ dm: XMTPiOS.Dm, client: AnyClientProvider) async -> JoinRequestResult? {
        guard let messages = try? await dm.messages(afterNs: nil) else { return nil }

        let candidates = messages.filter { message in
            guard let contentType = try? message.encodedContent.type,
                  contentType == ContentTypeText,
                  message.senderInboxId != client.inboxId else {
                return false
            }
            return true
        }

        for message in candidates {
            if let result = await processJoinRequest(message: message, client: client) {
                try? await dm.updateConsentState(state: .allowed)
                return result
            }
        }
        return nil
    }

    private func blockDM(conversationId: String, client: AnyClientProvider) async {
        guard let dm = try? await client.conversationsProvider.findConversation(
            conversationId: conversationId
        ) else { return }

        try? await dm.updateConsentState(state: .denied)
    }

    private func sendJoinErrorIfPossible(
        _ errorType: InviteJoinErrorType,
        tag: String,
        conversationId: String,
        client: AnyClientProvider
    ) async {
        guard !tag.isEmpty,
              let dm = try? await client.conversationsProvider.findConversation(
                  conversationId: conversationId
              ) else { return }

        let error = InviteJoinError(errorType: errorType, inviteTag: tag, timestamp: Date())
        do {
            try await dm.sendInviteJoinError(error)
        } catch {
            Log.error("Failed to send invite join error: \(error)")
        }
    }
}

// MARK: - Dm Extension

extension XMTPiOS.Dm {
    func lastMessageAsSignedInvite(sentBy clientInboxId: String) async -> SignedInvite? {
        guard let lastMessage = try? await self.lastMessage(),
              lastMessage.senderInboxId == clientInboxId,
              let contentType = try? lastMessage.encodedContent.type,
              contentType == ContentTypeText,
              let text: String = try? lastMessage.content(),
              let invite = try? SignedInvite.fromURLSafeSlug(text) else {
            return nil
        }
        return invite
    }
}
