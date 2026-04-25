import ConvosInvitesCore
import ConvosMessagingProtocols
import Foundation
// FIXME(stage6f-step8): `@preconcurrency import XMTPiOS` remains because
// `processMessage(_:client:)` is still typed against
// `XMTPiOS.DecodedMessage` (its production caller in
// `InviteJoinRequestsManager.processJoinRequest` passes the raw
// XMTPiOS-decoded message), and the
// `XMTPiOS.ContentTypeID.asMessagingContentType` bridge below is
// scoped to the existing codec constants
// (`ContentTypeJoinRequest`, `ContentTypeInviteJoinError`). Stage 6f
// Step 7 lifted the InviteClientProvider surface and the coordinator's
// `findConversation` / `findOrCreateDm` / `listDms` callsites onto
// Messaging* types so DTU adapters become structurally possible. The
// remaining XMTPiOS-typed boundary (DecodedMessage in / content-type
// bridge) is deferred to Step 8.
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
        for group: any MessagingGroup,
        client: any InviteClientProvider,
        options: InviteOptions = InviteOptions()
    ) async throws -> InviteCreationResult {
        let inboxId = client.inviteInboxId
        let privateKey = try await privateKeyProvider(inboxId)
        let tag = try await tagStorage.getInviteTag(for: group)

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
    public func revokeInvites(for group: any MessagingGroup) async throws -> String {
        try await tagStorage.regenerateInviteTag(for: group)
    }

    // MARK: - Join Request Sending (Joiner Side)

    public func sendJoinRequest(
        for signedInvite: SignedInvite,
        client: any InviteClientProvider,
        profile: JoinRequestProfile? = nil,
        metadata: [String: String]? = nil
    ) async throws -> any MessagingDm {
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
        let joinRequestBytes = try JSONEncoder().encode(joinRequest)
        let joinRequestEncoded = MessagingEncodedContent(
            type: ContentTypeJoinRequest.asMessagingContentType,
            content: joinRequestBytes,
            fallback: slug
        )
        _ = try await dm.sendOptimistic(
            encodedContent: joinRequestEncoded,
            options: MessagingSendOptions(
                contentType: ContentTypeJoinRequest.asMessagingContentType
            )
        )

        // Plain-text follow-up — mirrors the `dm.send(content: slug)`
        // that the legacy XMTPiOS path produced.
        let textEncoded = MessagingEncodedContent(
            type: .text,
            parameters: ["encoding": "UTF-8"],
            content: Data(slug.utf8)
        )
        _ = try await dm.sendOptimistic(
            encodedContent: textEncoded,
            options: MessagingSendOptions(contentType: .text)
        )

        return dm
    }

    // MARK: - Join Request Processing (Creator Side)

    public func processMessage(
        _ message: XMTPiOS.DecodedMessage,
        client: any InviteClientProvider
    ) async -> JoinResult? {
        guard message.senderInboxId != client.inviteInboxId else { return nil }

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
            return nil
        }

        guard let signedInvite = try? SignedInvite.fromURLSafeSlug(slug) else { return nil }

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
        guard let dms = try? await client.listDms(
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
        for group: any MessagingGroup,
        client: any InviteClientProvider
    ) async throws -> Bool {
        let tag: String
        do {
            tag = try await tagStorage.getInviteTag(for: group)
        } catch {
            return false
        }
        guard !tag.isEmpty else { return false }

        let dms = try await client.listDms(
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
              (try? await conversation.core.consentState()) == .allowed else {
            await sendJoinError(.conversationExpired, for: request, client: client)
            delegate?.coordinator(self, didRejectJoinRequest: request, error: .conversationNotFound(conversationId))
            return nil
        }

        guard case .group(let group) = conversation else {
            await sendJoinError(.genericFailure, for: request, client: client)
            delegate?.coordinator(self, didRejectJoinRequest: request, error: .invalidFormat)
            return nil
        }

        try? await group.sync()

        do {
            let currentTag = try await tagStorage.getInviteTag(for: group)
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
            try await group.addMembers(inboxIds: [request.joinerInboxId])
        } catch {
            await sendJoinError(.genericFailure, for: request, client: client)
            delegate?.coordinator(self, didRejectJoinRequest: request, error: .addMemberFailed)
            return nil
        }

        if let dmConversation = try? await client.findConversation(conversationId: request.dmConversationId) {
            try? await dmConversation.core.updateConsentState(.allowed)
        }

        let result = JoinResult(
            conversationId: conversationId,
            joinerInboxId: request.joinerInboxId,
            conversationName: try? await group.name(),
            profile: request.profile,
            metadata: request.metadata
        )
        delegate?.coordinator(self, didAddMember: result)
        return result
    }

    // MARK: - Helpers

    private func processDm(
        _ dm: any MessagingDm,
        client: any InviteClientProvider
    ) async -> JoinResult? {
        guard let messages = try? await dm.messages(query: MessagingMessageQuery()) else { return nil }

        let candidates = messages.filter { message in
            let contentType = message.encodedContent.type
            let isInviteContent = contentType == ContentTypeText.asMessagingContentType
                || contentType == ContentTypeJoinRequest.asMessagingContentType
            return isInviteContent && message.senderInboxId != client.inviteInboxId
        }

        for message in candidates {
            if let result = await processMessage(message, client: client) {
                try? await dm.updateConsentState(.allowed)
                return result
            }
        }
        return nil
    }

    /// Stage 6f Step 7 internal overload for the
    /// `processDm`/`processMessage` on-Messaging-types path. Decodes the
    /// abstraction-layer `MessagingMessage` content via the codec to
    /// produce the `JoinRequestContent` / `String`-text payloads
    /// previously consumed via XMTPiOS's content-type registry.
    private func processMessage(
        _ message: MessagingMessage,
        client: any InviteClientProvider
    ) async -> JoinResult? {
        guard message.senderInboxId != client.inviteInboxId else { return nil }

        let contentType = message.encodedContent.type
        let slug: String
        var profile: JoinRequestProfile?
        var metadata: [String: String]?

        if contentType == ContentTypeJoinRequest.asMessagingContentType {
            guard let joinRequest = try? JSONDecoder().decode(
                JoinRequestContent.self,
                from: message.encodedContent.content
            ) else { return nil }
            slug = joinRequest.inviteSlug
            profile = joinRequest.profile
            metadata = joinRequest.metadata
        } else if contentType == ContentTypeText.asMessagingContentType {
            guard let text = String(data: message.encodedContent.content, encoding: .utf8) else { return nil }
            slug = text
        } else {
            return nil
        }

        guard let signedInvite = try? SignedInvite.fromURLSafeSlug(slug) else { return nil }

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

    private func blockSpammer(
        _ request: JoinRequest,
        client: any InviteClientProvider
    ) async {
        if let conversation = try? await client.findConversation(conversationId: request.dmConversationId) {
            try? await conversation.core.updateConsentState(.denied)
        }
        delegate?.coordinator(self, didBlockSpammer: request.joinerInboxId, in: request.dmConversationId)
    }

    private func sendJoinError(
        _ errorType: InviteJoinErrorType,
        for request: JoinRequest,
        client: any InviteClientProvider
    ) async {
        guard let conversation = try? await client.findConversation(conversationId: request.dmConversationId) else {
            return
        }

        let error = InviteJoinError(
            errorType: errorType,
            inviteTag: request.signedInvite.invitePayload.tag,
            timestamp: Date()
        )

        // Encode via the codec's bytes pathway so the wire format is
        // exactly what `InviteJoinErrorCodec` would have produced, then
        // wrap as `MessagingEncodedContent` for the abstraction-layer
        // send. The codec's `encode` returns an XMTPiOS `EncodedContent`
        // whose `content` field is the JSON we want here.
        let codec = InviteJoinErrorCodec()
        guard let encodedJoinError = try? codec.encode(content: error) else { return }
        let messagingEncoded = MessagingEncodedContent(
            type: ContentTypeInviteJoinError.asMessagingContentType,
            parameters: encodedJoinError.parameters,
            content: encodedJoinError.content,
            fallback: try? codec.fallback(content: error)
        )
        _ = try? await conversation.core.sendOptimistic(
            encodedContent: messagingEncoded,
            options: MessagingSendOptions(
                contentType: ContentTypeInviteJoinError.asMessagingContentType
            )
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

// MARK: - MessagingDm Extension

extension MessagingDm {
    /// Stage 6f Step 7: relocated from `XMTPiOS.Dm` to `MessagingDm`
    /// so the body works against the abstraction surface (DTU + XMTPiOS
    /// both back this method).
    func lastMessageAsSignedInvite(sentBy clientInboxId: String) async -> SignedInvite? {
        guard let lastMessage = try? await self.lastMessage(),
              lastMessage.senderInboxId == clientInboxId else {
            return nil
        }

        let contentType = lastMessage.encodedContent.type
        let slug: String
        if contentType == ContentTypeJoinRequest.asMessagingContentType {
            guard let joinRequest = try? JSONDecoder().decode(
                JoinRequestContent.self,
                from: lastMessage.encodedContent.content
            ) else { return nil }
            slug = joinRequest.inviteSlug
        } else if contentType == ContentTypeText.asMessagingContentType {
            guard let text = String(data: lastMessage.encodedContent.content, encoding: .utf8) else { return nil }
            slug = text
        } else {
            return nil
        }

        return try? SignedInvite.fromURLSafeSlug(slug)
    }
}

// MARK: - Content Type Bridges

/// Stage 6f Step 7 bridge: converts an XMTPiOS `ContentTypeID` to the
/// abstraction-layer `MessagingContentType` so codec-typed
/// constants (`ContentTypeJoinRequest`, `ContentTypeInviteJoinError`,
/// XMTPiOS's `ContentTypeText`) can be compared against
/// `MessagingMessage.encodedContent.type`.
extension XMTPiOS.ContentTypeID {
    var asMessagingContentType: MessagingContentType {
        MessagingContentType(
            authorityID: authorityID,
            typeID: typeID,
            versionMajor: Int(versionMajor),
            versionMinor: Int(versionMinor)
        )
    }
}

extension MessagingContentType {
    /// `xmtp.org/text:1.0` — duplicated here from
    /// `ConvosCore`'s `MessagingContentType+XIP.swift` because
    /// `ConvosInvites` cannot import ConvosCore (circular).
    static let text: MessagingContentType = MessagingContentType(
        authorityID: "xmtp.org",
        typeID: "text",
        versionMajor: 1,
        versionMinor: 0
    )
}
