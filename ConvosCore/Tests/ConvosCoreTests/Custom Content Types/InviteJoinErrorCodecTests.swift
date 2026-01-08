@testable import ConvosCore
import Foundation
import Testing
import XMTPiOS

@Suite("InviteJoinError Codec Tests")
struct InviteJoinErrorCodecTests {
    let codec = InviteJoinErrorCodec()

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

    @Test("Encode and decode unknown error type")
    func encodeDecodeUnknownErrorType() throws {
        let originalError = InviteJoinError(
            errorType: .unknown("future_error"),
            inviteTag: "test-tag",
            timestamp: Date()
        )

        let encodedContent = try codec.encode(content: originalError)
        let decodedError: InviteJoinError = try codec.decode(content: encodedContent)

        #expect(decodedError.errorType == .unknown("future_error"))
        #expect(decodedError.inviteTag == "test-tag")
    }

    @Test("Forward compatibility with unknown error types")
    func forwardCompatibilityUnknownTypes() throws {
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

        #expect(decodedError.errorType == .unknown("new_error_type_from_future"))
        #expect(decodedError.inviteTag == "future-tag")
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

    @Test("Fallback content for unknown error")
    func fallbackUnknown() throws {
        let error = InviteJoinError(
            errorType: .unknown("custom_error"),
            inviteTag: "test-tag",
            timestamp: Date()
        )

        let fallback = try codec.fallback(content: error)
        #expect(fallback == "Failed to join conversation")
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

    @Test("User facing message for unknown error")
    func userFacingMessageUnknown() {
        let error = InviteJoinError(
            errorType: .unknown("future_error"),
            inviteTag: "test-tag",
            timestamp: Date()
        )

        #expect(error.userFacingMessage == "Failed to join conversation")
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

        #expect(decodedError.inviteTag == "")
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
        #expect(InviteJoinErrorType.genericFailure == .genericFailure)
        #expect(InviteJoinErrorType.unknown("test") == .unknown("test"))
        #expect(InviteJoinErrorType.unknown("test1") != .unknown("test2"))
        #expect(InviteJoinErrorType.conversationExpired != .genericFailure)
    }

    @Test("InviteJoinErrorType rawValue")
    func errorTypeRawValue() {
        #expect(InviteJoinErrorType.conversationExpired.rawValue == "conversation_expired")
        #expect(InviteJoinErrorType.genericFailure.rawValue == "generic_failure")
        #expect(InviteJoinErrorType.unknown("custom").rawValue == "custom")
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
        let incompleteJSON = """
        {
            "errorType": "conversation_expired"
        }
        """.data(using: .utf8)!

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
