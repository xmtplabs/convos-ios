@testable import ConvosInvites
import Foundation
import Testing
import XMTPiOS

@Suite("InviteJoinError Codec Tests")
struct InviteJoinErrorCodecTests {
    let codec: InviteJoinErrorCodec = InviteJoinErrorCodec()

    @Test("Codec content type matches expected value")
    func codecContentType() {
        let expectedType = ContentTypeID(
            authorityID: "convos.org",
            typeID: "invite_join_error",
            versionMajor: 1,
            versionMinor: 0
        )
        #expect(codec.contentType == expectedType)
        #expect(codec.contentType == ContentTypeInviteJoinError)
    }

    @Test("Codec should push notifications")
    func codecShouldPush() throws {
        #expect(try codec.shouldPush(content: InviteJoinError(
            errorType: .conversationExpired,
            inviteTag: "test-tag",
            timestamp: Date()
        )) == true)
    }

    @Test("Encode and decode conversationExpired error")
    func encodeDecodeConversationExpired() throws {
        let originalError = InviteJoinError(
            errorType: .conversationExpired,
            inviteTag: "test-invite-123",
            timestamp: Date()
        )

        let encodedContent = try codec.encode(content: originalError)
        let decodedError: InviteJoinError = try codec.decode(content: encodedContent)

        #expect(decodedError.errorType == .conversationExpired)
        #expect(decodedError.inviteTag == "test-invite-123")
        #expect(abs(decodedError.timestamp.timeIntervalSince(originalError.timestamp)) < 1.0)
    }

    @Test("Encode and decode genericFailure error")
    func encodeDecodeGenericFailure() throws {
        let originalError = InviteJoinError(
            errorType: .genericFailure,
            inviteTag: "invite-abc",
            timestamp: Date()
        )

        let encodedContent = try codec.encode(content: originalError)
        let decodedError: InviteJoinError = try codec.decode(content: encodedContent)

        #expect(decodedError.errorType == .genericFailure)
        #expect(decodedError.inviteTag == "invite-abc")
    }

    @Test("Encode and decode conversationNotFound error")
    func encodeDecodeConversationNotFound() throws {
        let originalError = InviteJoinError(
            errorType: .conversationNotFound,
            inviteTag: "tag-not-found",
            timestamp: Date()
        )

        let encodedContent = try codec.encode(content: originalError)
        let decodedError: InviteJoinError = try codec.decode(content: encodedContent)

        #expect(decodedError.errorType == .conversationNotFound)
        #expect(decodedError.inviteTag == "tag-not-found")
    }

    @Test("Encode and decode consentNotAllowed error")
    func encodeDecodeConsentNotAllowed() throws {
        let originalError = InviteJoinError(
            errorType: .consentNotAllowed,
            inviteTag: "tag-consent",
            timestamp: Date()
        )

        let encodedContent = try codec.encode(content: originalError)
        let decodedError: InviteJoinError = try codec.decode(content: encodedContent)

        #expect(decodedError.errorType == .consentNotAllowed)
        #expect(decodedError.inviteTag == "tag-consent")
    }

    @Test("Backward compatibility: unknown rawValue decodes to conversationExpired")
    func backwardCompatUnknownDecodesToConversationExpired() throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601

        struct FutureError: Codable {
            let errorType: String
            let inviteTag: String
            let timestamp: Date
        }

        let futureError = FutureError(
            errorType: "new_error_type_from_future",
            inviteTag: "future-tag",
            timestamp: Date()
        )

        let jsonData = try encoder.encode(futureError)
        var encodedContent = EncodedContent()
        encodedContent.type = ContentTypeInviteJoinError
        encodedContent.content = jsonData

        let decodedError: InviteJoinError = try codec.decode(content: encodedContent)

        #expect(decodedError.errorType == .conversationExpired)
        #expect(decodedError.inviteTag == "future-tag")
        #expect(decodedError.userFacingMessage == "This conversation is no longer available")
    }

    @Test("Backward compatibility: numeric-string rawValue decodes to conversationExpired")
    func backwardCompatNumericRawValueDecodesToConversationExpired() throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601

        struct FutureError: Codable {
            let errorType: String
            let inviteTag: String
            let timestamp: Date
        }

        let futureError = FutureError(
            errorType: "99",
            inviteTag: "tag-99",
            timestamp: Date()
        )

        let jsonData = try encoder.encode(futureError)
        var encodedContent = EncodedContent()
        encodedContent.type = ContentTypeInviteJoinError
        encodedContent.content = jsonData

        let decodedError: InviteJoinError = try codec.decode(content: encodedContent)

        #expect(decodedError.errorType == .conversationExpired)
    }

    @Test("Fallback content for conversationExpired")
    func fallbackConversationExpired() throws {
        let error = InviteJoinError(
            errorType: .conversationExpired,
            inviteTag: "test-tag",
            timestamp: Date()
        )

        let fallback = try codec.fallback(content: error)
        #expect(fallback == "This conversation is no longer available")
    }

    @Test("Fallback content for genericFailure")
    func fallbackGenericFailure() throws {
        let error = InviteJoinError(
            errorType: .genericFailure,
            inviteTag: "test-tag",
            timestamp: Date()
        )

        let fallback = try codec.fallback(content: error)
        #expect(fallback == "Failed to join conversation")
    }

    @Test("Fallback content for conversationNotFound")
    func fallbackConversationNotFound() throws {
        let error = InviteJoinError(
            errorType: .conversationNotFound,
            inviteTag: "test-tag",
            timestamp: Date()
        )

        let fallback = try codec.fallback(content: error)
        #expect(fallback == "This conversation is no longer available")
    }

    @Test("Fallback content for consentNotAllowed")
    func fallbackConsentNotAllowed() throws {
        let error = InviteJoinError(
            errorType: .consentNotAllowed,
            inviteTag: "test-tag",
            timestamp: Date()
        )

        let fallback = try codec.fallback(content: error)
        #expect(fallback == "This conversation is no longer available")
    }

    @Test("User facing message for conversationExpired")
    func userFacingMessageConversationExpired() {
        let error = InviteJoinError(
            errorType: .conversationExpired,
            inviteTag: "test-tag",
            timestamp: Date()
        )

        #expect(error.userFacingMessage == "This conversation is no longer available")
    }

    @Test("User facing message for genericFailure")
    func userFacingMessageGenericFailure() {
        let error = InviteJoinError(
            errorType: .genericFailure,
            inviteTag: "test-tag",
            timestamp: Date()
        )

        #expect(error.userFacingMessage == "Failed to join conversation")
    }

    @Test("User facing message for conversationNotFound")
    func userFacingMessageConversationNotFound() {
        let error = InviteJoinError(
            errorType: .conversationNotFound,
            inviteTag: "test-tag",
            timestamp: Date()
        )

        #expect(error.userFacingMessage == "This conversation is no longer available")
    }

    @Test("User facing message for consentNotAllowed")
    func userFacingMessageConsentNotAllowed() {
        let error = InviteJoinError(
            errorType: .consentNotAllowed,
            inviteTag: "test-tag",
            timestamp: Date()
        )

        #expect(error.userFacingMessage == "This conversation is no longer available")
    }

    @Test("Invite tags with special characters")
    func inviteTagsSpecialCharacters() throws {
        let specialTags = [
            "tag-with-dashes",
            "tag_with_underscores",
            "tag.with.dots",
            "tag123numbers",
            "MixedCaseTag"
        ]

        for tag in specialTags {
            let error = InviteJoinError(
                errorType: .conversationExpired,
                inviteTag: tag,
                timestamp: Date()
            )

            let encodedContent = try codec.encode(content: error)
            let decodedError: InviteJoinError = try codec.decode(content: encodedContent)

            #expect(decodedError.inviteTag == tag)
        }
    }

    @Test("Empty invite tag")
    func emptyInviteTag() throws {
        let error = InviteJoinError(
            errorType: .genericFailure,
            inviteTag: "",
            timestamp: Date()
        )

        let encodedContent = try codec.encode(content: error)
        let decodedError: InviteJoinError = try codec.decode(content: encodedContent)

        #expect(decodedError.inviteTag.isEmpty)
    }

    @Test("Very long invite tag")
    func veryLongInviteTag() throws {
        let longTag = String(repeating: "a", count: 1000)
        let error = InviteJoinError(
            errorType: .conversationExpired,
            inviteTag: longTag,
            timestamp: Date()
        )

        let encodedContent = try codec.encode(content: error)
        let decodedError: InviteJoinError = try codec.decode(content: encodedContent)

        #expect(decodedError.inviteTag == longTag)
    }

    @Test("Timestamp precision preserved")
    func timestampPrecision() throws {
        let originalTimestamp = Date()
        let error = InviteJoinError(
            errorType: .genericFailure,
            inviteTag: "test-tag",
            timestamp: originalTimestamp
        )

        let encodedContent = try codec.encode(content: error)
        let decodedError: InviteJoinError = try codec.decode(content: encodedContent)

        let timeDifference = abs(decodedError.timestamp.timeIntervalSince(originalTimestamp))
        #expect(timeDifference < 1.0)
    }

    @Test("InviteJoinError Equatable conformance")
    func equatableConformance() {
        let timestamp = Date()

        let error1 = InviteJoinError(
            errorType: .conversationExpired,
            inviteTag: "test-tag",
            timestamp: timestamp
        )

        let error2 = InviteJoinError(
            errorType: .conversationExpired,
            inviteTag: "test-tag",
            timestamp: timestamp
        )

        let error3 = InviteJoinError(
            errorType: .genericFailure,
            inviteTag: "test-tag",
            timestamp: timestamp
        )

        #expect(error1 == error2)
        #expect(error1 != error3)
    }

    @Test("InviteJoinErrorType Equatable conformance")
    func errorTypeEquatable() {
        #expect(InviteJoinErrorType.conversationExpired == .conversationExpired)
        #expect(InviteJoinErrorType.conversationNotFound == .conversationNotFound)
        #expect(InviteJoinErrorType.consentNotAllowed == .consentNotAllowed)
        #expect(InviteJoinErrorType.genericFailure == .genericFailure)
        #expect(InviteJoinErrorType.conversationExpired != .genericFailure)
        #expect(InviteJoinErrorType.conversationNotFound != .conversationExpired)
        #expect(InviteJoinErrorType.consentNotAllowed != .conversationNotFound)
    }

    @Test("InviteJoinErrorType rawValue")
    func errorTypeRawValue() {
        #expect(InviteJoinErrorType.conversationExpired.rawValue == "conversation_expired")
        #expect(InviteJoinErrorType.conversationNotFound.rawValue == "conversation_not_found")
        #expect(InviteJoinErrorType.consentNotAllowed.rawValue == "consent_not_allowed")
        #expect(InviteJoinErrorType.genericFailure.rawValue == "generic_failure")
    }

    @Test("InviteJoinErrorType init from known rawValues")
    func errorTypeInitFromKnownRawValues() {
        #expect(InviteJoinErrorType(rawValue: "conversation_expired") == .conversationExpired)
        #expect(InviteJoinErrorType(rawValue: "conversation_not_found") == .conversationNotFound)
        #expect(InviteJoinErrorType(rawValue: "consent_not_allowed") == .consentNotAllowed)
        #expect(InviteJoinErrorType(rawValue: "generic_failure") == .genericFailure)
    }

    @Test("InviteJoinErrorType init from unknown rawValue falls back to conversationExpired")
    func errorTypeInitFallback() {
        #expect(InviteJoinErrorType(rawValue: "totally_new_thing") == .conversationExpired)
        #expect(InviteJoinErrorType(rawValue: "") == .conversationExpired)
        #expect(InviteJoinErrorType(rawValue: "99") == .conversationExpired)
    }

    @Test("Decode malformed JSON throws error")
    func decodeMalformedJSON() {
        let malformedData = Data("not valid json".utf8)
        var encodedContent = EncodedContent()
        encodedContent.type = ContentTypeInviteJoinError
        encodedContent.content = malformedData

        #expect(throws: Error.self) {
            _ = try codec.decode(content: encodedContent) as InviteJoinError
        }
    }

    @Test("Decode incomplete JSON throws error")
    func decodeIncompleteJSON() throws {
        let incompleteJSON = Data("""
        {
            "errorType": "conversation_expired"
        }
        """.utf8)

        var encodedContent = EncodedContent()
        encodedContent.type = ContentTypeInviteJoinError
        encodedContent.content = incompleteJSON

        #expect(throws: Error.self) {
            _ = try codec.decode(content: encodedContent) as InviteJoinError
        }
    }

    @Test("Multiple errors with same tag are distinct")
    func multipleErrorsSameTag() throws {
        let tag = "shared-tag"
        let errors = [
            InviteJoinError(errorType: .conversationExpired, inviteTag: tag, timestamp: Date()),
            InviteJoinError(errorType: .genericFailure, inviteTag: tag, timestamp: Date())
        ]

        for error in errors {
            let encodedContent = try codec.encode(content: error)
            let decodedError: InviteJoinError = try codec.decode(content: encodedContent)

            #expect(decodedError.errorType == error.errorType)
            #expect(decodedError.inviteTag == tag)
        }
    }
}
