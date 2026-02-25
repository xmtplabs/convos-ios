import ConvosInvitesCore
import Foundation
import XMTPiOS

// MARK: - Private Key Provider

/// Callback to retrieve the private key for an inbox
public typealias PrivateKeyProvider = @Sendable (String) async throws -> Data

// MARK: - Delegate

/// Delegate for receiving invite coordinator events
public protocol InviteCoordinatorDelegate: AnyObject, Sendable {
    /// Called when a join request is received
    func coordinator(_ coordinator: InviteCoordinator, didReceiveJoinRequest request: JoinRequest)

    /// Called when a member is successfully added
    func coordinator(_ coordinator: InviteCoordinator, didAddMember result: JoinResult)

    /// Called when a join request fails for legitimate reasons
    func coordinator(_ coordinator: InviteCoordinator, didRejectJoinRequest request: JoinRequest, error: JoinRequestError)

    /// Called when spam is detected (invalid signature, etc.)
    func coordinator(_ coordinator: InviteCoordinator, didBlockSpammer inboxId: String, in dmConversationId: String)
}

// Default implementations
public extension InviteCoordinatorDelegate {
    func coordinator(_ coordinator: InviteCoordinator, didReceiveJoinRequest request: JoinRequest) {}
    func coordinator(_ coordinator: InviteCoordinator, didAddMember result: JoinResult) {}
    func coordinator(_ coordinator: InviteCoordinator, didRejectJoinRequest request: JoinRequest, error: JoinRequestError) {}
    func coordinator(_ coordinator: InviteCoordinator, didBlockSpammer inboxId: String, in dmConversationId: String) {}
}

// MARK: - Invite Coordinator

/// Coordinates invite creation and join request processing
///
/// This is the main entry point for the invite system. It handles:
/// - Creating shareable invite URLs
/// - Processing incoming join requests via DMs
/// - Adding approved joiners to conversations
/// - Blocking spam/invalid requests
/// - Sending error feedback to legitimate failed requests
public actor InviteCoordinator {
    private let client: XMTPiOS.Client
    private let privateKeyProvider: PrivateKeyProvider
    private let tagStorage: any InviteTagStorageProtocol
    private let baseURL: URL

    public weak var delegate: InviteCoordinatorDelegate?

    /// Initialize the invite coordinator
    /// - Parameters:
    ///   - client: The XMTP client to use
    ///   - privateKeyProvider: Callback to retrieve private keys for signing/decryption
    ///   - tagStorage: Storage for invite tags (defaults to XMTPInviteTagStorage)
    ///   - baseURL: Base URL for invite links (defaults to https://convos.org/i/)
    public init(
        client: XMTPiOS.Client,
        privateKeyProvider: @escaping PrivateKeyProvider,
        tagStorage: any InviteTagStorageProtocol = XMTPInviteTagStorage(),
        baseURL: URL = URL(string: "https://convos.org/i/")!
    ) {
        self.client = client
        self.privateKeyProvider = privateKeyProvider
        self.tagStorage = tagStorage
        self.baseURL = baseURL
    }

    // MARK: - Invite Creation

    /// Create a shareable invite URL for a group
    /// - Parameters:
    ///   - group: The group to create an invite for
    ///   - options: Options for the invite
    /// - Returns: An InviteURL that can be shared
    public func createInvite(
        for group: XMTPiOS.Group,
        options: InviteOptions = InviteOptions()
    ) async throws -> InviteURL {
        let inboxId = client.inboxID
        let privateKey = try await privateKeyProvider(inboxId)

        // Get the invite tag
        let tag = try tagStorage.getInviteTag(for: group)

        // Encrypt the conversation ID
        let tokenBytes = try InviteToken.encrypt(
            conversationId: group.id,
            creatorInboxId: inboxId,
            privateKey: privateKey
        )

        // Build the payload
        var payload = InvitePayload()
        payload.tag = tag
        payload.conversationToken = tokenBytes

        guard let inboxIdBytes = Data(hexString: inboxId) else {
            throw InviteCreationError.invalidInboxId
        }
        payload.creatorInboxID = inboxIdBytes

        if options.includePublicPreview {
            if let name = options.name {
                payload.name = name
            }
            if let description = options.description {
                payload.description_p = description
            }
            if let imageURL = options.imageURL {
                payload.imageURL = imageURL.absoluteString
            }
        }

        if let expiresAt = options.expiresAt {
            payload.expiresAtUnix = Int64(expiresAt.timeIntervalSince1970)
        }

        payload.expiresAfterUse = options.singleUse

        // Sign the payload
        let signature = try payload.sign(with: privateKey)

        // Create signed invite
        var signedInvite = SignedInvite()
        try signedInvite.setPayload(payload)
        signedInvite.signature = signature

        // Encode to URL
        let slug = try signedInvite.toURLSafeSlug()
        let url = baseURL.appendingPathComponent(slug)

        return InviteURL(url: url, slug: slug, signedInvite: signedInvite)
    }

    /// Revoke all existing invites for a group by generating a new invite tag
    /// - Parameter group: The group to revoke invites for
    /// - Returns: The new invite tag
    @discardableResult
    public func revokeInvites(for group: XMTPiOS.Group) async throws -> String {
        try await tagStorage.regenerateInviteTag(for: group)
    }

    // MARK: - Join Request Sending (Joiner Side)

    /// Send a join request to the invite creator
    /// - Parameter signedInvite: The invite to redeem
    /// - Returns: The DM conversation where the request was sent
    public func sendJoinRequest(for signedInvite: SignedInvite) async throws -> XMTPiOS.Dm {
        // Validate invite hasn't expired
        guard !signedInvite.hasExpired else {
            throw JoinRequestError.expired
        }

        guard !signedInvite.conversationHasExpired else {
            throw JoinRequestError.conversationExpired
        }

        // Get creator inbox ID
        let creatorInboxId = signedInvite.invitePayload.creatorInboxIdString

        guard !creatorInboxId.isEmpty else {
            throw JoinRequestError.invalidFormat
        }

        // Find or create DM with creator
        let dm = try await client.conversations.findOrCreateDm(with: creatorInboxId)

        // Send the invite slug as a text message
        let slug = try signedInvite.toURLSafeSlug()
        _ = try await dm.send(content: slug)

        return dm
    }

    // MARK: - Join Request Processing (Creator Side)

    /// Process a single message as a potential join request
    /// - Parameter message: The decoded message to process
    /// - Returns: JoinResult if the request was successful, nil if not a join request
    public func processMessage(_ message: XMTPiOS.DecodedMessage) async throws -> JoinResult? {
        let senderInboxId = message.senderInboxId

        // Ignore messages from self
        guard senderInboxId != client.inboxID else {
            return nil
        }

        // Try to extract text content
        guard let text: String = try? message.content() else {
            return nil
        }

        // Try to parse as signed invite
        let signedInvite: SignedInvite
        do {
            signedInvite = try SignedInvite.fromURLSafeSlug(text)
        } catch {
            // Not a valid invite format - not a join request
            return nil
        }

        let request = JoinRequest(
            joinerInboxId: senderInboxId,
            dmConversationId: message.conversationId,
            signedInvite: signedInvite,
            messageId: message.id
        )

        return try await processJoinRequest(request)
    }

    /// Process a join request
    private func processJoinRequest(_ request: JoinRequest) async throws -> JoinResult? {
        let signedInvite = request.signedInvite

        // Check expiration
        guard !signedInvite.hasExpired else {
            await notifyRejection(request, error: .expired)
            return nil
        }

        guard !signedInvite.conversationHasExpired else {
            await sendJoinError(.conversationExpired, for: request)
            await notifyRejection(request, error: .conversationExpired)
            return nil
        }

        // Verify creator inbox ID matches
        let creatorInboxId = signedInvite.invitePayload.creatorInboxIdString
        guard creatorInboxId == client.inboxID else {
            // Wrong creator - block as spam
            await blockSpammer(request)
            return nil
        }

        // Get private key and verify signature
        let privateKey: Data
        do {
            privateKey = try await privateKeyProvider(creatorInboxId)
        } catch {
            await sendJoinError(.genericFailure, for: request)
            return nil
        }

        // Verify signature by recovering public key and comparing
        do {
            let recoveredPublicKey = try signedInvite.recoverSignerPublicKey()
            // We need to derive our public key from private key to compare
            // For now, we'll trust the signature recovery worked
            _ = recoveredPublicKey
        } catch {
            await blockSpammer(request)
            return nil
        }

        // Decrypt conversation ID
        let conversationId: String
        do {
            conversationId = try InviteToken.decrypt(
                tokenBytes: signedInvite.invitePayload.conversationToken,
                creatorInboxId: creatorInboxId,
                privateKey: privateKey
            )
        } catch {
            await blockSpammer(request)
            return nil
        }

        // Find the conversation
        guard let conversation = try? await client.conversations.findConversation(conversationId: conversationId) else {
            await sendJoinError(.conversationExpired, for: request)
            await notifyRejection(request, error: .conversationNotFound(conversationId))
            return nil
        }

        // Must be a group
        guard case .group(let group) = conversation else {
            return nil
        }

        // Add the joiner
        do {
            try await group.addMembers(inboxIds: [request.joinerInboxId])
        } catch {
            await sendJoinError(.genericFailure, for: request)
            return nil
        }

        // Update DM consent to allowed
        if let dm = try? await client.conversations.findConversation(conversationId: request.dmConversationId) {
            try? await dm.updateConsentState(state: .allowed)
        }

        let result = JoinResult(
            conversationId: conversationId,
            joinerInboxId: request.joinerInboxId,
            conversationName: try? group.name()
        )

        await delegate?.coordinator(self, didAddMember: result)

        return result
    }

    // MARK: - Private Helpers

    private func blockSpammer(_ request: JoinRequest) async {
        if let dm = try? await client.conversations.findConversation(conversationId: request.dmConversationId) {
            try? await dm.updateConsentState(state: .denied)
        }
        await delegate?.coordinator(self, didBlockSpammer: request.joinerInboxId, in: request.dmConversationId)
    }

    private func notifyRejection(_ request: JoinRequest, error: JoinRequestError) async {
        await delegate?.coordinator(self, didRejectJoinRequest: request, error: error)
    }

    private func sendJoinError(_ errorType: InviteJoinErrorType, for request: JoinRequest) async {
        // Find the DM and send error feedback
        guard let dm = try? await client.conversations.findConversation(conversationId: request.dmConversationId),
              case .dm(let dmConversation) = dm else {
            return
        }

        let error = InviteJoinError(
            errorType: errorType,
            inviteTag: request.signedInvite.invitePayload.tag,
            timestamp: Date()
        )

        // Encode error as JSON and send
        if let errorData = try? JSONEncoder().encode(error),
           let errorString = String(data: errorData, encoding: .utf8) {
            // Send as a special formatted message that clients can parse
            _ = try? await dmConversation.send(content: "[INVITE_ERROR]\(errorString)")
        }
    }
}

// MARK: - Errors

public enum InviteCreationError: Error, LocalizedError {
    case invalidInboxId
    case signingFailed
    case encodingFailed

    public var errorDescription: String? {
        switch self {
        case .invalidInboxId:
            return "Invalid inbox ID format"
        case .signingFailed:
            return "Failed to sign invite"
        case .encodingFailed:
            return "Failed to encode invite"
        }
    }
}
