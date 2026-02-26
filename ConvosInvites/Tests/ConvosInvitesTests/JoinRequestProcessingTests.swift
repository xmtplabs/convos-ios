@testable import ConvosInvites
@testable import ConvosInvitesCore
import Foundation
import Testing

/// Tests for the join request validation logic used by InviteCoordinator.
///
/// These tests verify the core validation steps without requiring a live XMTP
/// client. Each test exercises a specific check that processJoinRequest performs.
@Suite("Join Request Processing Tests")
struct JoinRequestProcessingTests {
    private let privateKey: Data = Data((1...32).map { UInt8($0) })
    private let inboxId: String = Data(repeating: 0xAB, count: 20).toHexString()

    private func makeSignedInvite(
        conversationId: String = "conv-123",
        creatorInboxId: String? = nil,
        privateKey overrideKey: Data? = nil,
        expiresAt: Date? = nil,
        conversationExpiresAt: Date? = nil,
        tag: String = "test-tag"
    ) throws -> SignedInvite {
        let key = overrideKey ?? privateKey
        let creator = creatorInboxId ?? inboxId

        let tokenBytes = try InviteToken.encrypt(
            conversationId: conversationId,
            creatorInboxId: creator,
            privateKey: key
        )

        guard let creatorBytes = Data(hexString: creator) else {
            throw InviteCreationError.invalidInboxId
        }

        var payload = InvitePayload()
        payload.tag = tag
        payload.conversationToken = tokenBytes
        payload.creatorInboxID = creatorBytes

        if let expiresAt {
            payload.expiresAtUnix = Int64(expiresAt.timeIntervalSince1970)
        }

        if let conversationExpiresAt {
            payload.conversationExpiresAtUnix = Int64(conversationExpiresAt.timeIntervalSince1970)
        }

        let signature = try payload.sign(with: key)

        var signedInvite = SignedInvite()
        try signedInvite.setPayload(payload)
        signedInvite.signature = signature

        return signedInvite
    }

    // MARK: - Invite Expiration

    @Test("Rejects expired invite")
    func rejectsExpiredInvite() throws {
        let invite = try makeSignedInvite(
            expiresAt: Date(timeIntervalSinceNow: -3600)
        )

        #expect(invite.hasExpired)
    }

    @Test("Accepts non-expired invite")
    func acceptsNonExpiredInvite() throws {
        let invite = try makeSignedInvite(
            expiresAt: Date(timeIntervalSinceNow: 3600)
        )

        #expect(!invite.hasExpired)
    }

    @Test("Accepts invite with no expiration")
    func acceptsNoExpirationInvite() throws {
        let invite = try makeSignedInvite()

        #expect(!invite.hasExpired)
    }

    // MARK: - Conversation Expiration

    @Test("Rejects invite for expired conversation")
    func rejectsExpiredConversation() throws {
        let invite = try makeSignedInvite(
            conversationExpiresAt: Date(timeIntervalSinceNow: -3600)
        )

        #expect(invite.conversationHasExpired)
    }

    @Test("Accepts invite for non-expired conversation")
    func acceptsNonExpiredConversation() throws {
        let invite = try makeSignedInvite(
            conversationExpiresAt: Date(timeIntervalSinceNow: 3600)
        )

        #expect(!invite.conversationHasExpired)
    }

    // MARK: - Creator Inbox ID Validation

    @Test("Extracts creator inbox ID from invite")
    func extractsCreatorInboxId() throws {
        let invite = try makeSignedInvite()

        #expect(invite.invitePayload.creatorInboxIdString == inboxId)
    }

    @Test("Rejects invite with empty creator inbox ID")
    func rejectsEmptyCreatorInboxId() throws {
        var payload = InvitePayload()
        payload.tag = "test"
        payload.conversationToken = Data(repeating: 0x01, count: 32)
        // creatorInboxID left empty

        let signature = try payload.sign(with: privateKey)

        var invite = SignedInvite()
        try invite.setPayload(payload)
        invite.signature = signature

        #expect(invite.invitePayload.creatorInboxIdString.isEmpty)
    }

    // MARK: - Signature Verification

    @Test("Valid signature passes verification")
    func validSignatureVerifies() throws {
        let invite = try makeSignedInvite()
        let publicKey = try Data.derivePublicKey(from: privateKey)

        #expect(try invite.verify(with: publicKey))
    }

    @Test("Invite signed by wrong key fails verification")
    func wrongKeyFailsVerification() throws {
        let wrongKey = Data((33...64).map { UInt8($0) })
        let invite = try makeSignedInvite(privateKey: wrongKey)
        let publicKey = try Data.derivePublicKey(from: privateKey)

        #expect(try !invite.verify(with: publicKey))
    }

    @Test("Tampered payload fails verification")
    func tamperedPayloadFailsVerification() throws {
        let invite = try makeSignedInvite()
        let publicKey = try Data.derivePublicKey(from: privateKey)

        var tampered = invite
        var modifiedPayload = try tampered.payload
        modifiedPayload.append(0xFF)
        tampered.payload = modifiedPayload

        // Signature recovery will produce a different public key
        #expect(try !tampered.verify(with: publicKey))
    }

    // MARK: - Conversation Token Decryption

    @Test("Decrypts conversation ID from valid invite")
    func decryptsConversationId() throws {
        let conversationId = "group-abc-123"
        let invite = try makeSignedInvite(conversationId: conversationId)

        let decrypted = try InviteToken.decrypt(
            tokenBytes: invite.invitePayload.conversationToken,
            creatorInboxId: inboxId,
            privateKey: privateKey
        )

        #expect(decrypted == conversationId)
    }

    @Test("Decryption fails with wrong private key")
    func decryptionFailsWithWrongKey() throws {
        let invite = try makeSignedInvite(conversationId: "group-123")
        let wrongKey = Data((33...64).map { UInt8($0) })

        #expect(throws: (any Error).self) {
            _ = try InviteToken.decrypt(
                tokenBytes: invite.invitePayload.conversationToken,
                creatorInboxId: inboxId,
                privateKey: wrongKey
            )
        }
    }

    @Test("Decryption fails with wrong inbox ID")
    func decryptionFailsWithWrongInboxId() throws {
        let invite = try makeSignedInvite(conversationId: "group-123")
        let wrongInboxId = Data(repeating: 0xCD, count: 20).toHexString()

        #expect(throws: (any Error).self) {
            _ = try InviteToken.decrypt(
                tokenBytes: invite.invitePayload.conversationToken,
                creatorInboxId: wrongInboxId,
                privateKey: privateKey
            )
        }
    }

    // MARK: - Full Validation Flow

    @Test("Full flow: create invite, encode, decode, verify, decrypt")
    func fullValidationFlow() throws {
        let conversationId = "my-group-id"
        let publicKey = try Data.derivePublicKey(from: privateKey)

        let invite = try makeSignedInvite(conversationId: conversationId)

        let slug = try invite.toURLSafeSlug()
        let decoded = try SignedInvite.fromURLSafeSlug(slug)

        #expect(!decoded.hasExpired)
        #expect(!decoded.conversationHasExpired)
        #expect(decoded.invitePayload.creatorInboxIdString == inboxId)
        #expect(try decoded.verify(with: publicKey))

        let decryptedConversationId = try InviteToken.decrypt(
            tokenBytes: decoded.invitePayload.conversationToken,
            creatorInboxId: inboxId,
            privateKey: privateKey
        )
        #expect(decryptedConversationId == conversationId)
    }

    @Test("Full flow rejects when creator doesn't match")
    func fullFlowCreatorMismatch() throws {
        let otherInboxId = Data(repeating: 0xCD, count: 20).toHexString()
        let otherKey = Data((33...64).map { UInt8($0) })
        let myPublicKey = try Data.derivePublicKey(from: privateKey)

        let invite = try makeSignedInvite(
            creatorInboxId: otherInboxId,
            privateKey: otherKey
        )

        let slug = try invite.toURLSafeSlug()
        let decoded = try SignedInvite.fromURLSafeSlug(slug)

        #expect(decoded.invitePayload.creatorInboxIdString != inboxId)
        #expect(try !decoded.verify(with: myPublicKey))
    }

    // MARK: - Invite Tag

    @Test("Invite tag preserved through encode/decode")
    func inviteTagPreserved() throws {
        let invite = try makeSignedInvite(tag: "unique-tag-abc")

        let slug = try invite.toURLSafeSlug()
        let decoded = try SignedInvite.fromURLSafeSlug(slug)

        #expect(decoded.invitePayload.tag == "unique-tag-abc")
    }

    // MARK: - JoinRequest Model

    @Test("JoinRequest initialization")
    func joinRequestInit() throws {
        let invite = try makeSignedInvite()

        let request = JoinRequest(
            joinerInboxId: "joiner-inbox-id",
            dmConversationId: "dm-conv-id",
            signedInvite: invite,
            messageId: "msg-123"
        )

        #expect(request.joinerInboxId == "joiner-inbox-id")
        #expect(request.dmConversationId == "dm-conv-id")
        #expect(request.messageId == "msg-123")
        #expect(request.signedInvite.invitePayload.tag == "test-tag")
    }

    // MARK: - JoinResult Model

    @Test("JoinResult initialization")
    func joinResultInit() {
        let result = JoinResult(
            conversationId: "conv-123",
            joinerInboxId: "joiner-456",
            conversationName: "Test Group"
        )

        #expect(result.conversationId == "conv-123")
        #expect(result.joinerInboxId == "joiner-456")
        #expect(result.conversationName == "Test Group")
    }

    @Test("JoinResult with nil conversation name")
    func joinResultNilName() {
        let result = JoinResult(
            conversationId: "conv-123",
            joinerInboxId: "joiner-456",
            conversationName: nil
        )

        #expect(result.conversationName == nil)
    }

    // MARK: - JoinRequestError

    @Test("JoinRequestError cases")
    func joinRequestErrorCases() {
        let errors: [JoinRequestError] = [
            .invalidSignature,
            .expired,
            .conversationExpired,
            .conversationNotFound("conv-123"),
            .invalidFormat,
            .creatorMismatch,
            .revoked,
            .addMemberFailed,
        ]

        #expect(errors.count == 8)
    }

    // MARK: - InviteJoinError Feedback

    @Test("InviteJoinError round-trips through JSON")
    func inviteJoinErrorRoundTrip() throws {
        let error = InviteJoinError(
            errorType: .conversationExpired,
            inviteTag: "tag-123",
            timestamp: Date(timeIntervalSince1970: 1_000_000)
        )

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(error)

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let decoded = try decoder.decode(InviteJoinError.self, from: data)

        #expect(decoded.errorType == .conversationExpired)
        #expect(decoded.inviteTag == "tag-123")
        #expect(decoded.userFacingMessage == "This conversation is no longer available")
    }

    @Test("InviteJoinError generic failure message")
    func genericFailureMessage() {
        let error = InviteJoinError(
            errorType: .genericFailure,
            inviteTag: "tag",
            timestamp: Date()
        )

        #expect(error.userFacingMessage == "Failed to join conversation")
    }

    // MARK: - Date Extension

    @Test("Date nanoseconds conversion")
    func dateNanoseconds() {
        let date = Date(timeIntervalSince1970: 1.5)

        #expect(date.nanosecondsSince1970 == 1_500_000_000)
    }
}
