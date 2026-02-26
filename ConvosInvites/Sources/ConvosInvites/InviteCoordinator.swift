import ConvosInvitesCore
import Foundation
@preconcurrency import XMTPiOS

// MARK: - Private Key Provider

public typealias PrivateKeyProvider = @Sendable (String) async throws -> Data

// MARK: - Delegate

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
/// Takes an `InviteClientProvider` per call rather than holding one, so
/// the same coordinator instance can be reused across client changes
/// (e.g., account switches).
///
/// ## Usage
///
/// ```swift
/// let coordinator = InviteCoordinator(
///     privateKeyProvider: { inboxId in
///         try keychain.getPrivateKey(for: inboxId)
///     }
/// )
/// coordinator.delegate = self
///
/// let invite = try await coordinator.createInvite(for: group, client: xmtpClient)
/// let results = await coordinator.processJoinRequests(since: lastSync, client: xmtpClient)
/// ```
public final class InviteCoordinator: @unchecked Sendable {
    private let privateKeyProvider: PrivateKeyProvider
    private let tagStorage: any InviteTagStorageProtocol

    public weak var delegate: (any InviteCoordinatorDelegate)? {
        get { lock.withLock { _delegate } }
        set { lock.withLock { _delegate = newValue } }
    }

    private let lock: NSLock = .init()
    private weak var _delegate: (any InviteCoordinatorDelegate)?

    public init(
        privateKeyProvider: @escaping PrivateKeyProvider,
        tagStorage: any InviteTagStorageProtocol = ProtobufInviteTagStorage()
    ) {
        self.privateKeyProvider = privateKeyProvider
        self.tagStorage = tagStorage
    }

    // MARK: - Invite Creation

    public func createInvite(
        for group: XMTPiOS.Group,
        client: any InviteClientProvider,
        options: InviteOptions = InviteOptions()
    ) async throws -> InviteCreationResult {
        let inboxId = client.inviteInboxId
        let privateKey = try await privateKeyProvider(inboxId)
        let tag = try tagStorage.getInviteTag(for: group)

        let slug = try SignedInvite.createSlug(
            conversationId: group.id,
            creatorInboxId: inboxId,
            privateKey: privateKey,
            tag: tag,
            options: InviteSlugOptions(
                name: options.name,
                description: options.description,
                imageURL: options.imageURL?.absoluteString,
                expiresAt: options.expiresAt,
                expiresAfterUse: options.singleUse,
                includePublicPreview: options.includePublicPreview
            )
        )

        let signedInvite = try SignedInvite.fromURLSafeSlug(slug)
        return InviteCreationResult(slug: slug, signedInvite: signedInvite)
    }

    @discardableResult
    public func revokeInvites(for group: XMTPiOS.Group) async throws -> String {
        try await tagStorage.regenerateInviteTag(for: group)
    }

    // MARK: - Join Request Sending (Joiner Side)

    public func sendJoinRequest(
        for signedInvite: SignedInvite,
        client: any InviteClientProvider
    ) async throws -> XMTPiOS.Dm {
        guard !signedInvite.hasExpired else { throw JoinRequestError.expired }
        guard !signedInvite.conversationHasExpired else { throw JoinRequestError.conversationExpired }

        let creatorInboxId = signedInvite.invitePayload.creatorInboxIdString
        guard !creatorInboxId.isEmpty else { throw JoinRequestError.invalidFormat }

        let dm = try await client.findOrCreateDm(with: creatorInboxId)
        let slug = try signedInvite.toURLSafeSlug()
        _ = try await dm.send(content: slug)

        return dm
    }

    // MARK: - Join Request Processing (Creator Side)

    public func processMessage(
        _ message: XMTPiOS.DecodedMessage,
        client: any InviteClientProvider
    ) async -> JoinResult? {
        guard message.senderInboxId != client.inviteInboxId else { return nil }
        guard let text: String = try? message.content() else { return nil }
        guard let signedInvite = try? SignedInvite.fromURLSafeSlug(text) else { return nil }

        let request = JoinRequest(
            joinerInboxId: message.senderInboxId,
            dmConversationId: message.conversationId,
            signedInvite: signedInvite,
            messageId: message.id
        )

        return await processJoinRequest(request, client: client)
    }

    public func processJoinRequests(
        since: Date?,
        client: any InviteClientProvider
    ) async -> [JoinResult] {
        guard let dms = try? client.listDms(
            createdAfterNs: since?.nanosecondsSince1970,
            createdBeforeNs: nil,
            lastActivityBeforeNs: nil,
            lastActivityAfterNs: nil,
            limit: nil,
            consentStates: [.unknown],
            orderBy: .lastActivity
        ) else { return [] }

        var results: [JoinResult] = []
        for dm in dms {
            if let result = await processDm(dm, client: client) {
                results.append(result)
            }
        }
        return results
    }

    public func hasOutgoingJoinRequest(
        for group: XMTPiOS.Group,
        client: any InviteClientProvider
    ) async throws -> Bool {
        let tag: String
        do {
            tag = try tagStorage.getInviteTag(for: group)
        } catch {
            return false
        }
        guard !tag.isEmpty else { return false }

        let dms = try client.listDms(
            createdAfterNs: nil,
            createdBeforeNs: nil,
            lastActivityBeforeNs: nil,
            lastActivityAfterNs: nil,
            limit: nil,
            consentStates: [.allowed],
            orderBy: .lastActivity
        )

        for dm in dms {
            if let invite = await dm.lastMessageAsSignedInvite(sentBy: client.inviteInboxId),
               invite.invitePayload.tag == tag {
                return true
            }
        }
        return false
    }

    // MARK: - Core Processing

    // swiftlint:disable:next cyclomatic_complexity
    private func processJoinRequest(
        _ request: JoinRequest,
        client: any InviteClientProvider
    ) async -> JoinResult? {
        let signedInvite = request.signedInvite

        guard !signedInvite.hasExpired else {
            delegate?.coordinator(self, didRejectJoinRequest: request, error: .expired)
            return nil
        }

        guard !signedInvite.conversationHasExpired else {
            await sendJoinError(.conversationExpired, for: request, client: client)
            delegate?.coordinator(self, didRejectJoinRequest: request, error: .conversationExpired)
            return nil
        }

        let creatorInboxId = signedInvite.invitePayload.creatorInboxIdString

        guard !creatorInboxId.isEmpty else {
            await blockSpammer(request, client: client)
            return nil
        }

        guard creatorInboxId == client.inviteInboxId else {
            await blockSpammer(request, client: client)
            return nil
        }

        let privateKey: Data
        do {
            privateKey = try await privateKeyProvider(creatorInboxId)
        } catch {
            await sendJoinError(.genericFailure, for: request, client: client)
            delegate?.coordinator(self, didRejectJoinRequest: request, error: .invalidSignature)
            return nil
        }

        do {
            let expectedPublicKey = try Data.derivePublicKey(from: privateKey)
            guard try signedInvite.verify(with: expectedPublicKey) else {
                await blockSpammer(request, client: client)
                return nil
            }
        } catch let error as InviteSignatureError {
            switch error {
            case .invalidSignature, .verificationFailure:
                await blockSpammer(request, client: client)
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

        guard let conversation = try? await client.findConversation(conversationId: conversationId),
              (try? conversation.consentState()) == .allowed else {
            await sendJoinError(.conversationExpired, for: request, client: client)
            delegate?.coordinator(self, didRejectJoinRequest: request, error: .conversationNotFound(conversationId))
            return nil
        }

        guard case .group(let group) = conversation else {
            await sendJoinError(.genericFailure, for: request, client: client)
            delegate?.coordinator(self, didRejectJoinRequest: request, error: .invalidFormat)
            return nil
        }

        do {
            let currentTag = try tagStorage.getInviteTag(for: group)
            guard signedInvite.invitePayload.tag == currentTag else {
                await sendJoinError(.conversationExpired, for: request, client: client)
                delegate?.coordinator(self, didRejectJoinRequest: request, error: .revoked)
                return nil
            }
        } catch {
            await sendJoinError(.conversationExpired, for: request, client: client)
            delegate?.coordinator(self, didRejectJoinRequest: request, error: .revoked)
            return nil
        }

        do {
            _ = try await group.addMembers(inboxIds: [request.joinerInboxId])
        } catch {
            await sendJoinError(.genericFailure, for: request, client: client)
            delegate?.coordinator(self, didRejectJoinRequest: request, error: .addMemberFailed)
            return nil
        }

        if let dm = try? await client.findConversation(conversationId: request.dmConversationId) {
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

    // MARK: - Helpers

    private func processDm(
        _ dm: XMTPiOS.Dm,
        client: any InviteClientProvider
    ) async -> JoinResult? {
        guard let messages = try? await dm.messages(afterNs: nil) else { return nil }

        let candidates = messages.filter { message in
            guard let contentType = try? message.encodedContent.type,
                  contentType == ContentTypeText,
                  message.senderInboxId != client.inviteInboxId else {
                return false
            }
            return true
        }

        for message in candidates {
            if let result = await processMessage(message, client: client) {
                try? await dm.updateConsentState(state: .allowed)
                return result
            }
        }
        return nil
    }

    private func blockSpammer(
        _ request: JoinRequest,
        client: any InviteClientProvider
    ) async {
        if let dm = try? await client.findConversation(conversationId: request.dmConversationId) {
            try? await dm.updateConsentState(state: .denied)
        }
        delegate?.coordinator(self, didBlockSpammer: request.joinerInboxId, in: request.dmConversationId)
    }

    private func sendJoinError(
        _ errorType: InviteJoinErrorType,
        for request: JoinRequest,
        client: any InviteClientProvider
    ) async {
        guard let dm = try? await client.findConversation(conversationId: request.dmConversationId) else {
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
        case .invalidInboxId: return "Invalid inbox ID format"
        case .signingFailed: return "Failed to sign invite"
        case .encodingFailed: return "Failed to encode invite"
        }
    }
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
