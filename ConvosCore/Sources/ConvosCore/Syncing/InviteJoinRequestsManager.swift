import Foundation
import GRDB
import XMTPiOS

public enum InviteJoinRequestError: Error {
    case invalidSignature
    case conversationNotFound(String)
    case invalidConversationType
    case missingTextContent
    case invalidInviteFormat
    case expired
    case expiredConversation
    case malformedInboxId
}

public struct JoinRequestResult {
    public let conversationId: String
    public let conversationName: String?
}

protocol InviteJoinRequestsManagerProtocol {
    func processJoinRequest(
        message: XMTPiOS.DecodedMessage,
        client: AnyClientProvider
    ) async throws -> JoinRequestResult?
    func processJoinRequests(
        since: Date?,
        client: AnyClientProvider
    ) async -> [JoinRequestResult]
    func hasOutgoingJoinRequest(
        for conversation: XMTPiOS.Group,
        client: AnyClientProvider
    ) async throws -> Bool
}

/// Manages processing of conversation join requests via XMTP DMs
///
/// InviteJoinRequestsManager implements the server-less join approval flow:
///
/// **Join Request Processing:**
/// 1. Monitors incoming DMs for text messages containing signed invites
/// 2. Validates invite signature using recovered public key
/// 3. Decrypts conversation token to get conversation ID
/// 4. Verifies conversation exists and creator matches current inbox
/// 5. Adds requester to conversation if all checks pass
/// 6. Blocks DM and denies consent if invite is invalid (anti-spam)
///
/// **Security Checks:**
/// - Signature verification using secp256k1 ECDSA
/// - Creator inbox ID must match current user
/// - Invite and conversation expiration validation
/// - Conversation token decryption ensures only creator can process requests
///
/// **Spam Prevention:**
/// - Invalid invites result in immediate DM blocking (consent = denied)
/// - Prevents attackers from flooding DMs with fake join requests
///
/// This enables invitation-only conversations without a centralized approval server.
class InviteJoinRequestsManager: InviteJoinRequestsManagerProtocol {
    private let identityStore: any KeychainIdentityStoreProtocol
    private let databaseReader: any DatabaseReader

    init(identityStore: any KeychainIdentityStoreProtocol,
         databaseReader: any DatabaseReader) {
        self.identityStore = identityStore
        self.databaseReader = databaseReader
    }

    // MARK: - Public

    /// Process a message as a potential join request, with error handling
    /// - Parameters:
    ///   - message: The decoded message to process
    ///   - client: The XMTP client provider
    /// - Returns: The result if successful, nil otherwise
    private func processJoinRequestSafely(
        message: XMTPiOS.DecodedMessage,
        client: AnyClientProvider
    ) async -> JoinRequestResult? {
        do {
            if let result = try await processJoinRequest(
                message: message,
                client: client
            ) {
                Log.info("Successfully added \(message.senderInboxId) to conversation \(result.conversationId)")
                return result
            }
            return nil
        } catch InviteJoinRequestError.missingTextContent {
            // Silently skip - not a join request
            return nil
        } catch InviteJoinRequestError.invalidInviteFormat {
            // Silently skip - not a join request
            return nil
        } catch InviteJoinRequestError.invalidSignature {
            Log.error("Invalid signature in join request from \(message.senderInboxId)")
            return nil
        } catch InviteJoinRequestError.malformedInboxId {
            Log.error("Malformed inbox ID in join request from \(message.senderInboxId)")
            return nil
        } catch InviteJoinRequestError.conversationNotFound(let id) {
            Log.error("Conversation \(id) not found for join request from \(message.senderInboxId)")
            return nil
        } catch InviteJoinRequestError.invalidConversationType {
            Log.error("Join request targets a DM instead of a group")
            return nil
        } catch {
            Log.error("Error processing join request: \(error)")
            return nil
        }
    }

    /// Process a message as a potential join request
    /// - Parameters:
    ///   - message: The decoded message to process
    ///   - client: The XMTP client provider
    /// - Returns: The conversation details (ID and name) that the sender was added to, or nil if not a valid join request
    func processJoinRequest(
        message: XMTPiOS.DecodedMessage,
        client: AnyClientProvider
    ) async throws -> JoinRequestResult? {
        let senderInboxId = message.senderInboxId

        guard senderInboxId != client.inboxId else {
            Log.info("Ignoring outgoing join request...")
            return nil
        }

        let dbMessage = try message.dbRepresentation()
        guard let text = dbMessage.text else {
            Log.info("Message has no text content, not a join request")
            await blockDMConversation(client: client, conversationId: message.conversationId, senderInboxId: senderInboxId)
            throw InviteJoinRequestError.missingTextContent
        }

        // Try to parse as signed invite
        let signedInvite: SignedInvite
        do {
            signedInvite = try SignedInvite.fromURLSafeSlug(text)
        } catch {
            Log.info("Message text is not a valid signed invite format")
            throw InviteJoinRequestError.invalidInviteFormat
        }

        guard !signedInvite.hasExpired else {
            Log.info("Invite expired, cancelling join request...")
            throw InviteJoinRequestError.expired
        }

        guard !signedInvite.conversationHasExpired else {
            Log.info("Conversation expired, cancelling join request...")
            throw InviteJoinRequestError.expiredConversation
        }

        let creatorInboxId = signedInvite.invitePayload.creatorInboxIdString

        // validate that the invite contains a non-empty creator inbox ID
        guard !creatorInboxId.isEmpty else {
            await blockDMConversation(client: client, conversationId: message.conversationId, senderInboxId: senderInboxId)
            throw InviteJoinRequestError.malformedInboxId
        }

        guard creatorInboxId == client.inboxId else {
            Log.error("Received join request for invite not created by this inbox - blocking DM")
            await blockDMConversation(client: client, conversationId: message.conversationId, senderInboxId: senderInboxId)
            throw InviteJoinRequestError.invalidSignature
        }
        let identity = try await identityStore.identity(for: creatorInboxId)

        let publicKey = identity.keys.privateKey.publicKey.secp256K1Uncompressed.bytes

        // Verify the signature - explicitly handle both failure and errors
        let verifiedSignature: Bool
        do {
            verifiedSignature = try signedInvite.verify(with: publicKey)
        } catch {
            // Verification threw an exception (e.g., malformed signature, invalid key format)
            // This is different from a signature that doesn't match
            Log.error("Exception during signature verification for invite from \(senderInboxId): \(error) - blocking DM")
            await blockDMConversation(client: client, conversationId: message.conversationId, senderInboxId: senderInboxId)
            throw InviteJoinRequestError.invalidSignature
        }

        // Explicitly check that verification succeeded
        guard verifiedSignature == true else {
            // Signature verification returned false - signature doesn't match
            Log.error("Signature verification failed for invite from \(senderInboxId) - blocking DM")
            await blockDMConversation(client: client, conversationId: message.conversationId, senderInboxId: senderInboxId)
            throw InviteJoinRequestError.invalidSignature
        }

        let privateKey: Data = identity.keys.privateKey.secp256K1.bytes
        let conversationTokenBytes = signedInvite.invitePayload.conversationToken
        let conversationId = try InviteConversationToken.decodeConversationTokenBytes(
            conversationTokenBytes,
            creatorInboxId: client.inboxId,
            secp256k1PrivateKey: privateKey
        )

        guard let conversation = try await client.conversationsProvider.findConversation(
            conversationId: conversationId
        ), try conversation.consentState() == .allowed else {
            Log.warning("Conversation \(conversationId) not found for join request from \(senderInboxId)")
            throw InviteJoinRequestError.conversationNotFound(conversationId)
        }

        switch conversation {
        case .group(let group):
            Log.info("Adding \(senderInboxId) to group \(group.id)...")

            try await group.add(members: [senderInboxId])

            let conversationName = try? group.name()
            return JoinRequestResult(
                conversationId: group.id,
                conversationName: conversationName
            )
        case .dm:
            Log.warning("Expected Group but found DM from \(senderInboxId), ignoring invite join request")
            throw InviteJoinRequestError.invalidConversationType
        }
    }

    func hasOutgoingJoinRequest(for conversation: XMTPiOS.Group, client: AnyClientProvider) async throws -> Bool {
        let inviteTag = try conversation.inviteTag

        // List all DMs
        let dms = try client.conversationsProvider.listDms(
            createdAfterNs: nil,
            createdBeforeNs: nil,
            lastActivityBeforeNs: nil,
            lastActivityAfterNs: nil,
            limit: nil,
            consentStates: [.allowed],
            orderBy: .lastActivity
        )

        Log.info("Found \(dms.count) possible DMs containing outgoing join requests")

        for dm in dms {
            guard let invite = await dm.lastMessageAsSignedInvite(sentBy: client.inboxId) else {
                continue
            }

            // Check if this invite matches our target conversation
            if invite.invitePayload.tag == inviteTag {
                return true
            }
        }

        return false
    }

    /// Sync all DMs and process join requests, returning results
    /// - Parameter client: The XMTP client provider
    /// - Returns: Array of successfully processed join requests
    func processJoinRequests(since: Date?, client: AnyClientProvider) async -> [JoinRequestResult] {
        var results: [JoinRequestResult] = []

        do {
            Log.info("Listing all DMs for join requests...")

            // List all DMs with consent states .unknown
            let dms = try client.conversationsProvider.listDms(
                createdAfterNs: since?.nanosecondsSince1970,
                createdBeforeNs: nil,
                lastActivityBeforeNs: nil,
                lastActivityAfterNs: nil,
                limit: nil,
                consentStates: [.unknown],
                orderBy: .lastActivity
            )

            Log.info("Found \(dms.count) DMs to check for join requests")

            // Process each DM in parallel
            await withTaskGroup(of: JoinRequestResult?.self) { group in
                for dm in dms {
                    group.addTask { [weak self] in
                        do {
                            guard let self else { return nil }
                            return try await processMessages(for: dm, client: client)
                        } catch {
                            Log.error("Error processing messages as join requests: \(error.localizedDescription)")
                            return nil
                        }
                    }
                }

                for await result in group {
                    if let result = result {
                        results.append(result)
                    }
                }
            }

            Log.info("Completed DM sync for join requests")
        } catch {
            Log.error("Error syncing DMs: \(error)")
        }

        return results
    }

    // MARK: - Private Helpers

    private func processMessages(for dm: XMTPiOS.Dm, client: AnyClientProvider) async throws -> JoinRequestResult? {
        let messages = try await dm.messages(afterNs: nil)
            .filter { message in
                guard let encodedContentType = try? message.encodedContent.type else {
                    return false
                }

                switch encodedContentType {
                case ContentTypeText:
                    return message.senderInboxId != client.inboxId
                default:
                    return false
                }
            }
        Log.info("Found \(messages.count) messages as possible join requests")

        // Process each message and return first successful result for this DM
        for message in messages {
            if let result = await self.processJoinRequestSafely(
                message: message,
                client: client
            ) {
                // update the consent state so we don't process this dm again
                // NOTE: this will have to change if we start supporting 1+ convos per inbox
                try await dm.updateConsentState(state: .allowed)
                return result
            }
        }
        return nil
    }

    /// Blocks a DM conversation by setting its consent state to denied
    private func blockDMConversation(
        client: AnyClientProvider,
        conversationId: String,
        senderInboxId: String
    ) async {
        guard let dmConversation = try? await client.conversationsProvider.findConversation(
            conversationId: conversationId
        ) else {
            return
        }

        do {
            try await dmConversation.updateConsentState(state: .denied)
            Log.info("Set consent state to .denied for DM with \(senderInboxId)")
        } catch {
            Log.error("Failed to set consent state to .denied for DM with \(senderInboxId): \(error)")
        }
    }
}

// MARK: - Extensions

extension XMTPiOS.Dm {
    /// Returns the last message as a SignedInvite if it exists and is valid
    /// - Parameter clientInboxId: The inbox ID of the current client (to verify sender)
    /// - Returns: A SignedInvite if the last message is a valid text invite, nil otherwise
    func lastMessageAsSignedInvite(sentBy clientInboxId: String) async -> SignedInvite? {
        guard let lastMessage = try? await self.lastMessage() else {
            return nil
        }

        let content: String? = try? lastMessage.content()
        Log.info("Received last message: \(content ?? "nil") sender: \(lastMessage.senderInboxId)")

        // Only check messages sent by us
        guard lastMessage.senderInboxId == clientInboxId else {
            return nil
        }

        // Only check text messages
        guard let encodedContentType = try? lastMessage.encodedContent.type,
              encodedContentType == ContentTypeText else {
            return nil
        }

        // Try to parse as text and then as SignedInvite
        guard let text: String = try? lastMessage.content(),
              let invite = try? SignedInvite.fromURLSafeSlug(text) else {
            return nil
        }

        return invite
    }
}
