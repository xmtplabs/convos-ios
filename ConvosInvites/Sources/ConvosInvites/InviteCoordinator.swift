import ConvosInvitesCore
import Foundation
@preconcurrency import XMTPiOS

// MARK: - Private Key Provider

/// Callback to retrieve the private key for an inbox
public typealias PrivateKeyProvider = @Sendable (String) async throws -> Data

// MARK: - Delegate

/// Delegate for receiving invite coordinator events
public protocol InviteCoordinatorDelegate: AnyObject, Sendable {
    func coordinator(_ coordinator: InviteCoordinator, didReceiveJoinRequest request: JoinRequest)
    func coordinator(_ coordinator: InviteCoordinator, didAddMember result: JoinResult)
    func coordinator(_ coordinator: InviteCoordinator, didRejectJoinRequest request: JoinRequest, error: JoinRequestError)
    func coordinator(_ coordinator: InviteCoordinator, didBlockSpammer inboxId: String, in dmConversationId: String)
}

public extension InviteCoordinatorDelegate {
    func coordinator(_ coordinator: InviteCoordinator, didReceiveJoinRequest request: JoinRequest) {}
    func coordinator(_ coordinator: InviteCoordinator, didAddMember result: JoinResult) {}
    func coordinator(_ coordinator: InviteCoordinator, didRejectJoinRequest request: JoinRequest, error: JoinRequestError) {}
    func coordinator(_ coordinator: InviteCoordinator, didBlockSpammer inboxId: String, in dmConversationId: String) {}
}

// MARK: - Invite Coordinator

/// Coordinates invite creation and join request processing for XMTP groups.
///
/// This is the main entry point for the invite system. It handles:
/// - Creating shareable invite URLs
/// - Processing incoming join requests via DMs
/// - Adding approved joiners to conversations
/// - Blocking spam/invalid requests
/// - Sending error feedback to joiners when requests fail
///
/// ## Usage
///
/// ```swift
/// let coordinator = InviteCoordinator(
///     client: xmtpClient,
///     privateKeyProvider: { inboxId in
///         try keychain.getPrivateKey(for: inboxId)
///     }
/// )
/// coordinator.delegate = self
///
/// // Create an invite
/// let invite = try await coordinator.createInvite(
///     for: group,
///     options: InviteOptions(name: "My Group")
/// )
///
/// // Process a single incoming message
/// let result = try await coordinator.processMessage(message)
///
/// // Batch-process all pending DMs
/// let results = await coordinator.processJoinRequests(since: lastSyncDate)
/// ```
public actor InviteCoordinator {
    private let client: XMTPiOS.Client
    private let privateKeyProvider: PrivateKeyProvider
    private let tagStorage: any InviteTagStorageProtocol
    private let baseURL: URL

    public weak var delegate: InviteCoordinatorDelegate?

    public init(
        client: XMTPiOS.Client,
        privateKeyProvider: @escaping PrivateKeyProvider,
        tagStorage: any InviteTagStorageProtocol = ProtobufInviteTagStorage(),
        baseURL: URL = Constant.defaultBaseURL
    ) {
        self.client = client
        self.privateKeyProvider = privateKeyProvider
        self.tagStorage = tagStorage
        self.baseURL = baseURL
    }

    // MARK: - Invite Creation

    public func createInvite(
        for group: XMTPiOS.Group,
        options: InviteOptions = InviteOptions()
    ) async throws -> InviteURL {
        let inboxId = client.inboxID
        let privateKey = try await privateKeyProvider(inboxId)

        let tag = try tagStorage.getInviteTag(for: group)

        let tokenBytes = try InviteToken.encrypt(
            conversationId: group.id,
            creatorInboxId: inboxId,
            privateKey: privateKey
        )

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

        let signature = try payload.sign(with: privateKey)

        var signedInvite = SignedInvite()
        try signedInvite.setPayload(payload)
        signedInvite.signature = signature

        let slug = try signedInvite.toURLSafeSlug()
        let url = baseURL.appendingPathComponent(slug)

        return InviteURL(url: url, slug: slug, signedInvite: signedInvite)
    }

    @discardableResult
    public func revokeInvites(for group: XMTPiOS.Group) async throws -> String {
        try await tagStorage.regenerateInviteTag(for: group)
    }

    // MARK: - Join Request Sending (Joiner Side)

    public func sendJoinRequest(for signedInvite: SignedInvite) async throws -> XMTPiOS.Dm {
        guard !signedInvite.hasExpired else {
            throw JoinRequestError.expired
        }

        guard !signedInvite.conversationHasExpired else {
            throw JoinRequestError.conversationExpired
        }

        let creatorInboxId = signedInvite.invitePayload.creatorInboxIdString

        guard !creatorInboxId.isEmpty else {
            throw JoinRequestError.invalidFormat
        }

        let dm = try await client.conversations.findOrCreateDm(with: creatorInboxId)

        let slug = try signedInvite.toURLSafeSlug()
        _ = try await dm.send(content: slug)

        return dm
    }

    // MARK: - Join Request Processing (Creator Side)

    /// Process a single XMTP message as a potential join request.
    ///
    /// Returns a `JoinResult` if the message is a valid join request and the
    /// joiner was successfully added. Returns `nil` if the message is not a
    /// join request (e.g. regular text). Notifies the delegate on success,
    /// rejection, or spam detection.
    public func processMessage(_ message: XMTPiOS.DecodedMessage) async -> JoinResult? {
        let senderInboxId = message.senderInboxId

        guard senderInboxId != client.inboxID else {
            return nil
        }

        guard let text: String = try? message.content() else {
            return nil
        }

        guard let signedInvite = try? SignedInvite.fromURLSafeSlug(text) else {
            return nil
        }

        let request = JoinRequest(
            joinerInboxId: senderInboxId,
            dmConversationId: message.conversationId,
            signedInvite: signedInvite,
            messageId: message.id
        )

        return await processJoinRequest(request)
    }

    /// Scan DMs for pending join requests and process them.
    ///
    /// Lists all DMs with `.unknown` consent state (new, unprocessed DMs),
    /// checks each for valid join request messages, and processes them.
    ///
    /// - Parameter since: Only check DMs created after this date (nil = all)
    /// - Returns: All successfully processed join results
    public func processJoinRequests(since: Date?) async -> [JoinResult] {
        var results: [JoinResult] = []

        let dms: [XMTPiOS.Dm]
        do {
            dms = try client.conversations.listDms(
                createdAfterNs: since?.nanosecondsSince1970,
                createdBeforeNs: nil,
                lastActivityBeforeNs: nil,
                lastActivityAfterNs: nil,
                limit: nil,
                consentStates: [.unknown],
                orderBy: .lastActivity
            )
        } catch {
            return []
        }

        for dm in dms {
            if let result = await processDm(dm) {
                results.append(result)
            }
        }

        return results
    }

    /// Check whether we have already sent a join request for a given group.
    ///
    /// Scans allowed DMs for an outgoing message whose invite tag matches the
    /// group's current tag.
    public func hasOutgoingJoinRequest(for group: XMTPiOS.Group) async throws -> Bool {
        let tag: String
        do {
            tag = try tagStorage.getInviteTag(for: group)
        } catch {
            return false
        }
        guard !tag.isEmpty else { return false }

        let dms = try client.conversations.listDms(
            createdAfterNs: nil,
            createdBeforeNs: nil,
            lastActivityBeforeNs: nil,
            lastActivityAfterNs: nil,
            limit: nil,
            consentStates: [.allowed],
            orderBy: .lastActivity
        )

        for dm in dms {
            if let invite = await dm.lastMessageAsSignedInvite(sentBy: client.inboxID),
               invite.invitePayload.tag == tag {
                return true
            }
        }

        return false
    }

    // MARK: - Private Helpers

    private func processJoinRequest(_ request: JoinRequest) async -> JoinResult? {
        let signedInvite = request.signedInvite

        guard !signedInvite.hasExpired else {
            delegate?.coordinator(self, didRejectJoinRequest: request, error: .expired)
            return nil
        }

        guard !signedInvite.conversationHasExpired else {
            await sendJoinError(.conversationExpired, for: request)
            delegate?.coordinator(self, didRejectJoinRequest: request, error: .conversationExpired)
            return nil
        }

        let creatorInboxId = signedInvite.invitePayload.creatorInboxIdString

        guard !creatorInboxId.isEmpty else {
            await blockSpammer(request)
            return nil
        }

        guard creatorInboxId == client.inboxID else {
            await blockSpammer(request)
            return nil
        }

        let privateKey: Data
        do {
            privateKey = try await privateKeyProvider(creatorInboxId)
        } catch {
            await sendJoinError(.genericFailure, for: request)
            delegate?.coordinator(self, didRejectJoinRequest: request, error: .invalidSignature)
            return nil
        }

        do {
            let expectedPublicKey = try Data.derivePublicKey(from: privateKey)
            guard try signedInvite.verify(with: expectedPublicKey) else {
                await blockSpammer(request)
                return nil
            }
        } catch let error as InviteSignatureError {
            switch error {
            case .invalidSignature, .verificationFailure:
                await blockSpammer(request)
            case .invalidContext, .invalidPublicKey, .invalidPrivateKey,
                 .invalidFormat, .signatureFailure, .encodingFailure:
                delegate?.coordinator(self, didRejectJoinRequest: request, error: .invalidSignature)
            }
            return nil
        } catch {
            delegate?.coordinator(self, didRejectJoinRequest: request, error: .invalidSignature)
            return nil
        }

        let conversationId: String
        do {
            conversationId = try InviteToken.decrypt(
                tokenBytes: signedInvite.invitePayload.conversationToken,
                creatorInboxId: creatorInboxId,
                privateKey: privateKey
            )
        } catch {
            delegate?.coordinator(self, didRejectJoinRequest: request, error: .invalidFormat)
            return nil
        }

        guard let conversation = try? await client.conversations.findConversation(conversationId: conversationId),
              (try? conversation.consentState()) == .allowed else {
            await sendJoinError(.conversationExpired, for: request)
            delegate?.coordinator(self, didRejectJoinRequest: request, error: .conversationNotFound(conversationId))
            return nil
        }

        guard case .group(let group) = conversation else {
            delegate?.coordinator(self, didRejectJoinRequest: request, error: .invalidFormat)
            return nil
        }

        do {
            _ = try await group.addMembers(inboxIds: [request.joinerInboxId])
        } catch {
            await sendJoinError(.genericFailure, for: request)
            return nil
        }

        if let dm = try? await client.conversations.findConversation(conversationId: request.dmConversationId) {
            try? await dm.updateConsentState(state: .allowed)
        }

        let result = JoinResult(
            conversationId: conversationId,
            joinerInboxId: request.joinerInboxId,
            conversationName: try? group.name()
        )

        delegate?.coordinator(self, didAddMember: result)

        return result
    }

    private func processDm(_ dm: XMTPiOS.Dm) async -> JoinResult? {
        guard let messages = try? await dm.messages(afterNs: nil) else { return nil }

        let incomingTextMessages = messages.filter { message in
            guard let contentType = try? message.encodedContent.type,
                  contentType == ContentTypeText,
                  message.senderInboxId != client.inboxID else {
                return false
            }
            return true
        }

        for message in incomingTextMessages {
            if let result = await processMessage(message) {
                try? await dm.updateConsentState(state: .allowed)
                return result
            }
        }
        return nil
    }

    private func blockSpammer(_ request: JoinRequest) async {
        if let dm = try? await client.conversations.findConversation(conversationId: request.dmConversationId) {
            try? await dm.updateConsentState(state: .denied)
        }
        delegate?.coordinator(self, didBlockSpammer: request.joinerInboxId, in: request.dmConversationId)
    }

    private func sendJoinError(_ errorType: InviteJoinErrorType, for request: JoinRequest) async {
        guard let dm = try? await client.conversations.findConversation(conversationId: request.dmConversationId) else {
            return
        }

        let error = InviteJoinError(
            errorType: errorType,
            inviteTag: request.signedInvite.invitePayload.tag,
            timestamp: Date()
        )

        let codec = InviteJoinErrorCodec()
        _ = try? await dm.send(
            content: error,
            options: .init(contentType: codec.contentType)
        )
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

// MARK: - Constant

public enum Constant {
    // swiftlint:disable:next force_unwrapping
    public static let defaultBaseURL: URL = URL(string: "https://convos.org/i/")!
}

// MARK: - Date Extension

extension Date {
    var nanosecondsSince1970: Int64 {
        Int64(timeIntervalSince1970 * 1_000_000_000)
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
