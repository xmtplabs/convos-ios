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
        client: any InviteClientProvider,
        profile: JoinRequestProfile? = nil,
        metadata: [String: String]? = nil
    ) async throws -> XMTPiOS.Dm {
        guard !signedInvite.hasExpired else { throw JoinRequestError.expired }
        guard !signedInvite.conversationHasExpired else { throw JoinRequestError.conversationExpired }

        let creatorInboxId = signedInvite.invitePayload.creatorInboxIdString
        guard !creatorInboxId.isEmpty else { throw JoinRequestError.invalidFormat }

        let dm = try await client.findOrCreateDm(with: creatorInboxId)
        let slug = try signedInvite.toURLSafeSlug()
        let joinRequest = JoinRequestContent(
            inviteSlug: slug,
            profile: profile,
            metadata: metadata
        )
        let codec = JoinRequestCodec()
        _ = try await dm.send(
            content: joinRequest,
            options: .init(contentType: codec.contentType)
        )
        _ = try await dm.send(content: slug)

        return dm
    }

    // MARK: - Join Request Processing (Creator Side)

    public func processMessage(
        _ message: XMTPiOS.DecodedMessage,
        client: any InviteClientProvider
    ) async -> JoinResult? {
        let outcome = await processMessageOutcome(message, client: client)
        return outcome.joinResult
    }

    public func processMessageOutcome(
        _ message: XMTPiOS.DecodedMessage,
        client: any InviteClientProvider
    ) async -> JoinRequestDMOutcome {
        guard message.senderInboxId != client.inviteInboxId else { return .noJoinRequest }

        let slug: String
        var profile: JoinRequestProfile?
        var metadata: [String: String]?

        if let joinRequest: JoinRequestContent = try? message.content() {
            slug = joinRequest.inviteSlug
            profile = joinRequest.profile
            metadata = joinRequest.metadata
        } else if let text: String = try? message.content() {
            slug = text
        } else {
            return .noJoinRequest
        }

        guard let signedInvite = try? SignedInvite.fromURLSafeSlug(slug) else {
            return .noJoinRequest
        }

        let request = JoinRequest(
            joinerInboxId: message.senderInboxId,
            dmConversationId: message.conversationId,
            signedInvite: signedInvite,
            messageId: message.id,
            profile: profile,
            metadata: metadata
        )

        return await processJoinRequest(request, client: client)
    }

    public func processJoinRequests(
        since: Date?,
        client: any InviteClientProvider
    ) async -> [JoinResult] {
        let outcomes = await processJoinRequestOutcomes(since: since, client: client)
        return outcomes.compactMap(\.joinResult)
    }

    public func processJoinRequestOutcomes(
        since: Date?,
        client: any InviteClientProvider
    ) async -> [JoinRequestDMOutcome] {
        guard let dms = try? client.listDms(
            createdAfterNs: nil,
            createdBeforeNs: nil,
            lastActivityBeforeNs: nil,
            lastActivityAfterNs: since?.nanosecondsSince1970,
            limit: nil,
            consentStates: [.unknown, .allowed],
            orderBy: .lastActivity
        ) else { return [] }

        var outcomes: [JoinRequestDMOutcome] = []
        for dm in dms {
            let outcome = await processDm(dm, since: since, client: client)
            if case .noJoinRequest = outcome {
                continue
            }
            outcomes.append(outcome)
        }
        return outcomes
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
    ) async -> JoinRequestDMOutcome {
        let signedInvite = request.signedInvite

        guard !signedInvite.hasExpired else {
            delegate?.coordinator(self, didRejectJoinRequest: request, error: .expired)
            return benignFailure(request, error: .expired)
        }

        guard !signedInvite.conversationHasExpired else {
            await sendJoinError(.conversationExpired, for: request, client: client)
            delegate?.coordinator(self, didRejectJoinRequest: request, error: .conversationExpired)
            return benignFailure(request, error: .conversationExpired)
        }

        let creatorInboxId = signedInvite.invitePayload.creatorInboxIdString

        guard !creatorInboxId.isEmpty else {
            delegate?.coordinator(self, didRejectJoinRequest: request, error: .invalidFormat)
            return benignFailure(request, error: .invalidFormat)
        }

        guard creatorInboxId == client.inviteInboxId else {
            delegate?.coordinator(self, didRejectJoinRequest: request, error: .creatorMismatch)
            return benignFailure(request, error: .creatorMismatch)
        }

        let privateKey: Data
        do {
            privateKey = try await privateKeyProvider(creatorInboxId)
        } catch {
            await sendJoinError(.genericFailure, for: request, client: client)
            delegate?.coordinator(self, didRejectJoinRequest: request, error: .processingFailed)
            return benignFailure(request, error: .processingFailed)
        }

        do {
            let expectedPublicKey = try Data.derivePublicKey(from: privateKey)
            guard try signedInvite.verify(with: expectedPublicKey) else {
                return await denyDmForMaliciousInvite(request, client: client, error: .invalidSignature)
            }
        } catch let error as InviteSignatureError {
            switch error {
            case .invalidSignature, .verificationFailure:
                return await denyDmForMaliciousInvite(request, client: client, error: .invalidSignature)
            case .invalidContext, .invalidPublicKey, .invalidPrivateKey,
                 .invalidFormat, .signatureFailure, .encodingFailure:
                delegate?.coordinator(self, didRejectJoinRequest: request, error: .processingFailed)
                return benignFailure(request, error: .processingFailed)
            }
        } catch {
            delegate?.coordinator(self, didRejectJoinRequest: request, error: .processingFailed)
            return benignFailure(request, error: .processingFailed)
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
            return benignFailure(request, error: .invalidFormat)
        }

        guard let conversation = try? await client.findConversation(conversationId: conversationId) else {
            Log.warning("Rejecting join for \(conversationId) (inviteTag: \(request.signedInvite.invitePayload.tag)): conversation not found in local store")
            await sendJoinError(.conversationNotFound, for: request, client: client)
            delegate?.coordinator(self, didRejectJoinRequest: request, error: .conversationNotFound(conversationId))
            return benignFailure(request, error: .conversationNotFound(conversationId))
        }

        let consent = (try? conversation.consentState()) ?? .unknown
        guard consent == .allowed else {
            Log.warning("Rejecting join for \(conversationId) (inviteTag: \(request.signedInvite.invitePayload.tag)): consent state '\(consent)' is not .allowed")
            await sendJoinError(.consentNotAllowed, for: request, client: client)
            delegate?.coordinator(self, didRejectJoinRequest: request, error: .consentNotAllowed(conversationId, consent))
            return benignFailure(request, error: .consentNotAllowed(conversationId, consent))
        }

        guard case .group(let group) = conversation else {
            await sendJoinError(.genericFailure, for: request, client: client)
            delegate?.coordinator(self, didRejectJoinRequest: request, error: .invalidFormat)
            return benignFailure(request, error: .invalidFormat)
        }

        try? await group.sync()

        do {
            let currentTag = try tagStorage.getInviteTag(for: group)
            guard signedInvite.invitePayload.tag == currentTag else {
                await sendJoinError(.conversationExpired, for: request, client: client)
                delegate?.coordinator(self, didRejectJoinRequest: request, error: .revoked)
                return benignFailure(request, error: .revoked)
            }
        } catch {
            await sendJoinError(.conversationExpired, for: request, client: client)
            delegate?.coordinator(self, didRejectJoinRequest: request, error: .revoked)
            return benignFailure(request, error: .revoked)
        }

        do {
            _ = try await group.addMembers(inboxIds: [request.joinerInboxId])
        } catch {
            await sendJoinError(.genericFailure, for: request, client: client)
            delegate?.coordinator(self, didRejectJoinRequest: request, error: .addMemberFailed)
            return benignFailure(request, error: .addMemberFailed)
        }

        if let dm = try? await client.findConversation(conversationId: request.dmConversationId) {
            try? await dm.updateConsentState(state: .allowed)
        }

        let result = JoinResult(
            conversationId: conversationId,
            joinerInboxId: request.joinerInboxId,
            conversationName: try? group.name(),
            profile: request.profile,
            metadata: request.metadata
        )
        delegate?.coordinator(self, didAddMember: result)
        return .accepted(result, dmConversationId: request.dmConversationId)
    }

    // MARK: - Helpers

    private func processDm(
        _ dm: XMTPiOS.Dm,
        since: Date?,
        client: any InviteClientProvider
    ) async -> JoinRequestDMOutcome {
        guard let messages = try? await dm.messages(afterNs: since?.nanosecondsSince1970) else {
            return .benignFailure(
                dmConversationId: dm.id,
                senderInboxId: nil,
                error: .processingFailed
            )
        }

        let candidates = messages.filter { message in
            guard let contentType = try? message.encodedContent.type,
                  contentType == ContentTypeText || contentType == ContentTypeJoinRequest,
                  message.senderInboxId != client.inviteInboxId else {
                return false
            }
            return true
        }

        var firstBenignFailure: JoinRequestDMOutcome?
        for message in candidates {
            let outcome = await processMessageOutcome(message, client: client)
            switch outcome {
            case .noJoinRequest:
                continue
            case .accepted:
                try? await dm.updateConsentState(state: .allowed)
                return outcome
            case .malicious:
                return outcome
            case .benignFailure:
                firstBenignFailure = firstBenignFailure ?? outcome
                continue
            }
        }
        return firstBenignFailure ?? .noJoinRequest
    }

    private func benignFailure(
        _ request: JoinRequest,
        error: JoinRequestError
    ) -> JoinRequestDMOutcome {
        .benignFailure(
            dmConversationId: request.dmConversationId,
            senderInboxId: request.joinerInboxId,
            error: error
        )
    }

    private func denyDmForMaliciousInvite(
        _ request: JoinRequest,
        client: any InviteClientProvider,
        error: JoinRequestError
    ) async -> JoinRequestDMOutcome {
        if let dm = try? await client.findConversation(conversationId: request.dmConversationId) {
            try? await dm.updateConsentState(state: .denied)
        }
        delegate?.coordinator(self, didBlockSpammer: request.joinerInboxId, in: request.dmConversationId)
        return .malicious(
            dmConversationId: request.dmConversationId,
            senderInboxId: request.joinerInboxId,
            error: error
        )
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
              let contentType = try? lastMessage.encodedContent.type else {
            return nil
        }

        let slug: String
        if contentType == ContentTypeJoinRequest,
           let joinRequest: JoinRequestContent = try? lastMessage.content() {
            slug = joinRequest.inviteSlug
        } else if contentType == ContentTypeText,
                  let text: String = try? lastMessage.content() {
            slug = text
        } else {
            return nil
        }

        return try? SignedInvite.fromURLSafeSlug(slug)
    }
}
