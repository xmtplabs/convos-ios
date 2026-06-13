@testable import ConvosInvites
import Foundation
import Testing
import XMTPiOS

@Suite("InviteJoinHandled Codec Tests")
struct InviteJoinHandledCodecTests {
    let codec: InviteJoinHandledCodec = InviteJoinHandledCodec()

    @Test("Codec content type matches expected value")
    func codecContentType() {
        let expectedType = ContentTypeID(
            authorityID: "convos.org",
            typeID: "invite_join_handled",
            versionMajor: 1,
            versionMinor: 0
        )
        #expect(codec.contentType == expectedType)
        #expect(codec.contentType == ContentTypeInviteJoinHandled)
    }

    @Test("Codec does not push notifications")
    func codecShouldNotPush() throws {
        #expect(try codec.shouldPush(content: InviteJoinHandled(
            inviteTag: "test-tag",
            handledMessageId: "msg-1",
            timestamp: Date()
        )) == false)
    }

    @Test("Fallback is nil - markers are creator-side bookkeeping")
    func fallbackIsNil() throws {
        let handled = InviteJoinHandled(
            inviteTag: "test-tag",
            handledMessageId: "msg-1",
            timestamp: Date()
        )
        #expect(try codec.fallback(content: handled) == nil)
    }

    @Test("Encode and decode round-trips all fields")
    func encodeDecodeRoundTrip() throws {
        let original = InviteJoinHandled(
            inviteTag: "invite-abc",
            handledMessageId: "message-123",
            timestamp: Date()
        )

        let encodedContent = try codec.encode(content: original)
        let decoded: InviteJoinHandled = try codec.decode(content: encodedContent)

        #expect(decoded.inviteTag == "invite-abc")
        #expect(decoded.handledMessageId == "message-123")
        #expect(abs(decoded.timestamp.timeIntervalSince(original.timestamp)) < 1.0)
    }

    @Test("Decode empty content throws")
    func decodeEmptyContentThrows() {
        var encodedContent = EncodedContent()
        encodedContent.type = ContentTypeInviteJoinHandled
        encodedContent.content = Data()

        #expect(throws: Error.self) {
            _ = try codec.decode(content: encodedContent) as InviteJoinHandled
        }
    }

    @Test("Decode malformed JSON throws")
    func decodeMalformedJSONThrows() {
        var encodedContent = EncodedContent()
        encodedContent.type = ContentTypeInviteJoinHandled
        encodedContent.content = Data("not valid json".utf8)

        #expect(throws: Error.self) {
            _ = try codec.decode(content: encodedContent) as InviteJoinHandled
        }
    }

    @Test("InviteJoinHandled Equatable conformance")
    func equatableConformance() {
        let timestamp = Date()
        let first = InviteJoinHandled(inviteTag: "tag", handledMessageId: "msg-1", timestamp: timestamp)
        let second = InviteJoinHandled(inviteTag: "tag", handledMessageId: "msg-1", timestamp: timestamp)
        let third = InviteJoinHandled(inviteTag: "tag", handledMessageId: "msg-2", timestamp: timestamp)

        #expect(first == second)
        #expect(first != third)
    }
}
