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
    private let handledRequestStore: any HandledJoinRequestStoreProtocol

    public weak var delegate: (any InviteCoordinatorDelegate)? {
        get { lock.withLock { _delegate } }
        set { lock.withLock { _delegate = newValue } }
    }

    private let lock: NSLock = .init()
    private weak var _delegate: (any InviteCoordinatorDelegate)?

    public init(
        privateKeyProvider: @escaping PrivateKeyProvider,
        tagStorage: any InviteTagStorageProtocol = ProtobufInviteTagStorage(),
        handledRequestStore: any HandledJoinRequestStoreProtocol = InMemoryHandledJoinRequestStore()
    ) {
        self.privateKeyProvider = privateKeyProvider
        self.tagStorage = tagStorage
        self.handledRequestStore = handledRequestStore
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

        // The typed join_request content type is preferred, but a plain-text
        // slug is still accepted: every app build that predates the typed
        // joiner path sends text only, so dropping it strands those joiners
        // with no reply at all. Senders like Herald emit a text copy next to
        // the typed message; the duplicate does not produce a second error
        // reply because sendJoinError dedupes per attempt (both copies of a
        // pair predate whichever error is sent first). Text acceptance can
        // only be removed once the installed fleet sends typed requests.
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
            sentAt: message.sentAt,
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

    /// Result of one validation phase of join-request processing: either the
    /// value the next phase needs, or the outcome to return to the caller.
    private enum JoinStep<Value> {
        case proceed(Value)
        case stop(JoinRequestDMOutcome)
    }

    private func processJoinRequest(
        _ request: JoinRequest,
        client: any InviteClientProvider
    ) async -> JoinRequestDMOutcome {
        let conversationId: String
        switch await validateInviteAndDecryptConversationId(request, client: client) {
        case .proceed(let value):
            conversationId = value
        case .stop(let outcome):
            return outcome
        }

        let group: XMTPiOS.Group
        switch await resolveInvitedGroup(conversationId: conversationId, request: request, client: client) {
        case .proceed(let value):
            group = value
        case .stop(let outcome):
            return outcome
        }

        return await addJoinerToGroup(group, conversationId: conversationId, request: request, client: client)
    }

    private func validateInviteAndDecryptConversationId(
        _ request: JoinRequest,
        client: any InviteClientProvider
    ) async -> JoinStep<String> {
        let signedInvite = request.signedInvite

        guard !signedInvite.hasExpired else {
            delegate?.coordinator(self, didRejectJoinRequest: request, error: .expired)
            return .stop(benignFailure(request, error: .expired))
        }

        let creatorInboxId = signedInvite.invitePayload.creatorInboxIdString

        guard !creatorInboxId.isEmpty else {
            delegate?.coordinator(self, didRejectJoinRequest: request, error: .invalidFormat)
            return .stop(benignFailure(request, error: .invalidFormat))
        }

        guard creatorInboxId == client.inviteInboxId else {
            delegate?.coordinator(self, didRejectJoinRequest: request, error: .creatorMismatch)
            return .stop(benignFailure(request, error: .creatorMismatch))
        }

        let privateKey: Data
        do {
            privateKey = try await privateKeyProvider(creatorInboxId)
        } catch {
            Log.warning("Rejecting join (inviteTag: \(signedInvite.invitePayload.tag)): private key unavailable: \(error)")
            await sendJoinError(
                .genericFailure,
                reason: "creator private key unavailable",
                for: request,
                client: client
            )
            delegate?.coordinator(self, didRejectJoinRequest: request, error: .processingFailed)
            return .stop(benignFailure(request, error: .processingFailed))
        }

        do {
            let expectedPublicKey = try Data.derivePublicKey(from: privateKey)
            guard try signedInvite.verify(with: expectedPublicKey) else {
                return .stop(await denyDmForMaliciousInvite(request, client: client, error: .invalidSignature))
            }
        } catch let error as InviteSignatureError {
            // Threat-model split:
            // - `.invalidSignature` / `.verificationFailure` only occur once the
            //   signature has been parsed and run against the expected key — a
            //   mismatch here means the slug was tampered with, so we deny the
            //   DM and unsubscribe from its push topic.
            // - The remaining cases are parse / encoding / key-derivation
            //   failures that can happen on benign inputs (corrupt slug, format
            //   skew, transient keychain error). We treat these as recoverable
            //   so the same joiner can retry without being blocked.
            switch error {
            case .invalidSignature, .verificationFailure:
                return .stop(await denyDmForMaliciousInvite(request, client: client, error: .invalidSignature))
            case .invalidContext, .invalidPublicKey, .invalidPrivateKey,
                 .invalidFormat, .signatureFailure, .encodingFailure:
                delegate?.coordinator(self, didRejectJoinRequest: request, error: .processingFailed)
                return .stop(benignFailure(request, error: .processingFailed))
            }
        } catch {
            delegate?.coordinator(self, didRejectJoinRequest: request, error: .processingFailed)
            return .stop(benignFailure(request, error: .processingFailed))
        }

        // Checked only after signature verification: this branch sends an
        // error reply, and replying to unverified slugs would let anyone
        // forge an "expired" invite and reflect outbound DMs off the creator.
        guard !signedInvite.conversationHasExpired else {
            let expiresAt = signedInvite.conversationExpiresAt.map { "\($0)" } ?? "unknown"
            await sendJoinError(
                .conversationExpired,
                reason: "conversation expired at \(expiresAt)",
                for: request,
                client: client
            )
            delegate?.coordinator(self, didRejectJoinRequest: request, error: .conversationExpired)
            return .stop(benignFailure(request, error: .conversationExpired))
        }

        do {
            let conversationId = try InviteToken.decrypt(
                tokenBytes: signedInvite.invitePayload.conversationToken,
                creatorInboxId: creatorInboxId,
                privateKey: privateKey
            )
            return .proceed(conversationId)
        } catch {
            delegate?.coordinator(self, didRejectJoinRequest: request, error: .invalidFormat)
            return .stop(benignFailure(request, error: .invalidFormat))
        }
    }

    private func resolveInvitedGroup(
        conversationId: String,
        request: JoinRequest,
        client: any InviteClientProvider
    ) async -> JoinStep<XMTPiOS.Group> {
        var foundConversation = try? await client.findConversation(conversationId: conversationId)
        if foundConversation == nil {
            // findConversation is a local-only lookup. The group can be
            // missing from this installation's store even though it exists
            // (fresh install, secondary device), so pull new conversations
            // once before telling the joiner the conversation is gone.
            Log.info("Conversation \(conversationId) not found locally for join request, syncing conversations before rejecting")
            do {
                try await client.syncConversations()
            } catch {
                // A failed sync means we cannot distinguish "group doesn't
                // exist" from "we just couldn't fetch it" - treat it like
                // the consentState() throw below: transient, no error sent.
                Log.warning("Conversation sync failed while resolving join request for \(conversationId): \(error)")
                delegate?.coordinator(self, didRejectJoinRequest: request, error: .processingFailed)
                return .stop(benignFailure(request, error: .processingFailed))
            }
            foundConversation = try? await client.findConversation(conversationId: conversationId)
        }
        guard let conversation = foundConversation else {
            Log.warning("Rejecting join for \(conversationId) (inviteTag: \(request.signedInvite.invitePayload.tag)): conversation not found in local store after sync")
            await sendJoinError(
                .conversationNotFound,
                reason: "conversation not found in creator's local store after sync",
                for: request,
                client: client
            )
            delegate?.coordinator(self, didRejectJoinRequest: request, error: .conversationNotFound(conversationId))
            return .stop(benignFailure(request, error: .conversationNotFound(conversationId)))
        }

        let consent: ConsentState
        do {
            consent = try conversation.consentState()
        } catch {
            // A throw here is a local read failure, not an actual denial.
            // Treat it as transient so the joiner isn't told their valid
            // invite was rejected.
            Log.warning("Skipping join for \(conversationId) (inviteTag: \(request.signedInvite.invitePayload.tag)): reading consent state failed: \(error)")
            delegate?.coordinator(self, didRejectJoinRequest: request, error: .processingFailed)
            return .stop(benignFailure(request, error: .processingFailed))
        }
        guard consent == .allowed else {
            Log.warning("Rejecting join for \(conversationId) (inviteTag: \(request.signedInvite.invitePayload.tag)): consent state '\(consent)' is not .allowed")
            await sendJoinError(
                .consentNotAllowed,
                reason: "creator consent state is '\(consent)'",
                for: request,
                client: client
            )
            delegate?.coordinator(self, didRejectJoinRequest: request, error: .consentNotAllowed(conversationId, consent))
            return .stop(benignFailure(request, error: .consentNotAllowed(conversationId, consent)))
        }

        guard case .group(let group) = conversation else {
            await sendJoinError(
                .genericFailure,
                reason: "invite target is a DM, not a group",
                for: request,
                client: client
            )
            delegate?.coordinator(self, didRejectJoinRequest: request, error: .invalidFormat)
            return .stop(benignFailure(request, error: .invalidFormat))
        }

        return .proceed(group)
    }

    private func addJoinerToGroup(
        _ group: XMTPiOS.Group,
        conversationId: String,
        request: JoinRequest,
        client: any InviteClientProvider
    ) async -> JoinRequestDMOutcome {
        let signedInvite = request.signedInvite

        // A join-request message admits its sender at most once. Membership
        // alone cannot dedupe revalidation passes: after the creator removes
        // the member, the already-honored request would look actionable
        // again and silently re-add them. Removal is not a block - a removed
        // member rejoins by sending a fresh request (new message ID) with
        // the same invite.
        if await handledRequestStore.isHandled(messageId: request.messageId) {
            return .alreadyMember(
                dmConversationId: request.dmConversationId,
                joinerInboxId: request.joinerInboxId
            )
        }

        try? await group.sync()

        // Multiple processing paths (message stream, batch catch-up, and the
        // temporary agent-join poll) can see the same join-request message.
        // If the joiner is already in the group, a previous pass handled it -
        // skip the re-add so we don't send duplicate profile snapshots or,
        // worse, a spurious error DM back to a joiner that already joined.
        // Mark the request handled so it stays inert if the member is later
        // removed; this also retires requests honored before the ledger
        // existed, and the text copy of a typed+text pair.
        if let memberInboxIds = try? await group.members.map(\.inboxId),
           memberInboxIds.contains(request.joinerInboxId) {
            await handledRequestStore.markHandled(messageId: request.messageId)
            return .alreadyMember(
                dmConversationId: request.dmConversationId,
                joinerInboxId: request.joinerInboxId
            )
        }

        do {
            let currentTag = try tagStorage.getInviteTag(for: group)
            guard signedInvite.invitePayload.tag == currentTag else {
                // errorType stays .conversationExpired for older-client UX;
                // the reason distinguishes revocation from actual expiry.
                await sendJoinError(
                    .conversationExpired,
                    reason: "invite tag revoked or rotated since the invite was created",
                    for: request,
                    client: client
                )
                delegate?.coordinator(self, didRejectJoinRequest: request, error: .revoked)
                return benignFailure(request, error: .revoked)
            }
        } catch {
            Log.warning("Rejecting join (inviteTag: \(signedInvite.invitePayload.tag)): reading invite tag failed: \(error)")
            await sendJoinError(
                .conversationExpired,
                reason: "creator could not read the group's invite tag",
                for: request,
                client: client
            )
            delegate?.coordinator(self, didRejectJoinRequest: request, error: .revoked)
            return benignFailure(request, error: .revoked)
        }

        do {
            _ = try await group.addMembers(inboxIds: [request.joinerInboxId])
        } catch {
            // The full error stays in creator-side logs; the wire reason
            // carries only the error type name. Raw libxmtp descriptions can
            // embed member inbox IDs and storage internals, and the joiner
            // is an untrusted party.
            Log.warning("Rejecting join (inviteTag: \(signedInvite.invitePayload.tag)): addMembers failed: \(error)")
            await sendJoinError(
                .genericFailure,
                reason: "addMembers failed (\(type(of: error)))",
                for: request,
                client: client
            )
            delegate?.coordinator(self, didRejectJoinRequest: request, error: .addMemberFailed)
            return benignFailure(request, error: .addMemberFailed)
        }

        await handledRequestStore.markHandled(messageId: request.messageId)

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

        // Text slugs are still join requests: every build that predates the
        // typed joiner path (2.0.0 and earlier) sends text only. The Herald
        // typed+text pair does not double-reply because sendJoinError
        // dedupes per attempt. Remove ContentTypeText here only once the
        // installed fleet sends typed requests.
        let candidates = messages.filter { message in
            guard let contentType = try? message.encodedContent.type,
                  contentType == ContentTypeText || contentType == ContentTypeJoinRequest,
                  message.senderInboxId != client.inviteInboxId else {
                return false
            }
            return true
        }

        var firstBenignFailure: JoinRequestDMOutcome?
        var handledOutcome: JoinRequestDMOutcome?
        for message in candidates {
            // An already-honored request is inert, but it must not end the
            // scan: the same DM can carry a fresh join request from a member
            // who was removed and is rejoining with the same invite.
            if await handledRequestStore.isHandled(messageId: message.id) {
                handledOutcome = handledOutcome ?? .alreadyMember(
                    dmConversationId: dm.id,
                    joinerInboxId: message.senderInboxId
                )
                continue
            }
            let outcome = await processMessageOutcome(message, client: client)
            switch outcome {
            case .noJoinRequest:
                continue
            case .accepted:
                try? await dm.updateConsentState(state: .allowed)
                return outcome
            case .alreadyMember:
                return outcome
            case .malicious:
                return outcome
            case .benignFailure:
                firstBenignFailure = firstBenignFailure ?? outcome
                continue
            }
        }
        return firstBenignFailure ?? handledOutcome ?? .noJoinRequest
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
        reason: String,
        for request: JoinRequest,
        client: any InviteClientProvider
    ) async {
        guard let dm = try? await client.findConversation(conversationId: request.dmConversationId) else {
            return
        }

        // The same failed join request can be revalidated by several paths
        // (message stream, batch catch-up, agent-join poll), and nothing
        // marks a failure as handled the way `.alreadyMember` does for
        // successes. Skip the send if this DM already carries an error for
        // the same invite tag sent after this request's message, so each
        // failed attempt gets exactly one reply no matter how many passes
        // revalidate it. Errors older than the request don't count: a fresh
        // retry of the same invite deserves a fresh reply, otherwise the
        // joiner waits forever on an error that will never arrive.
        let inviteTag = request.signedInvite.invitePayload.tag
        if await hasAlreadySentJoinError(forTag: inviteTag, since: request.sentAt, in: dm, client: client) {
            return
        }

        let error = InviteJoinError(
            errorType: errorType,
            inviteTag: inviteTag,
            timestamp: Date(),
            reason: String(reason.prefix(Constant.joinErrorReasonMaxLength))
        )

        let codec = InviteJoinErrorCodec()
        _ = try? await dm.send(
            content: error,
            options: .init(contentType: codec.contentType)
        )
    }

    private func hasAlreadySentJoinError(
        forTag tag: String,
        since requestSentAt: Date?,
        in dm: XMTPiOS.Conversation,
        client: any InviteClientProvider
    ) async -> Bool {
        guard let messages = try? await dm.messages(limit: Constant.joinErrorDedupeScanLimit) else {
            return false
        }
        let codec = InviteJoinErrorCodec()
        for message in messages where message.senderInboxId == client.inviteInboxId {
            guard let contentType = try? message.encodedContent.type,
                  contentType == ContentTypeInviteJoinError,
                  let priorError = try? codec.decode(content: message.encodedContent) else {
                continue
            }
            if let requestSentAt, message.sentAt < requestSentAt {
                continue
            }
            if priorError.inviteTag == tag {
                return true
            }
        }
        return false
    }

    private enum Constant {
        /// How many recent DM messages to scan when checking whether an
        /// error reply for an invite tag was already sent. Join-request DMs
        /// carry very little traffic, so a small window is plenty.
        static let joinErrorDedupeScanLimit: Int = 50
        /// Underlying error descriptions (libxmtp, keychain) can be very
        /// long; cap the diagnostic reason so error replies stay small.
        static let joinErrorReasonMaxLength: Int = 500
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
