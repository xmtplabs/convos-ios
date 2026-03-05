@testable import ConvosInvites
import Foundation
import Testing
import XMTPiOS

@Suite("JoinRequest Codec Tests")
struct JoinRequestCodecTests {
    let codec: JoinRequestCodec = JoinRequestCodec()

    @Test("Codec content type matches expected value")
    func codecContentType() {
        let expectedType = ContentTypeID(
            authorityID: "convos.org",
            typeID: "join_request",
            versionMajor: 1,
            versionMinor: 0
        )
        #expect(codec.contentType == expectedType)
        #expect(codec.contentType == ContentTypeJoinRequest)
    }

    @Test("Codec should push notifications")
    func codecShouldPush() throws {
        let content = JoinRequestContent(inviteSlug: "test-slug")
        #expect(try codec.shouldPush(content: content) == true)
    }

    @Test("Encode and decode with invite slug only")
    func encodeDecodeSlugOnly() throws {
        let original = JoinRequestContent(inviteSlug: "abc123-invite-slug")

        let encoded = try codec.encode(content: original)
        let decoded: JoinRequestContent = try codec.decode(content: encoded)

        #expect(decoded.inviteSlug == "abc123-invite-slug")
        #expect(decoded.profile == nil)
        #expect(decoded.metadata == nil)
    }

    @Test("Encode and decode with profile")
    func encodeDecodeWithProfile() throws {
        let profile = JoinRequestProfile(name: "Alice", imageURL: "https://example.com/alice.jpg")
        let original = JoinRequestContent(inviteSlug: "slug-123", profile: profile)

        let encoded = try codec.encode(content: original)
        let decoded: JoinRequestContent = try codec.decode(content: encoded)

        #expect(decoded.inviteSlug == "slug-123")
        #expect(decoded.profile?.name == "Alice")
        #expect(decoded.profile?.imageURL == "https://example.com/alice.jpg")
        #expect(decoded.metadata == nil)
    }

    @Test("Encode and decode with profile name only")
    func encodeDecodeProfileNameOnly() throws {
        let profile = JoinRequestProfile(name: "Bob")
        let original = JoinRequestContent(inviteSlug: "slug-456", profile: profile)

        let encoded = try codec.encode(content: original)
        let decoded: JoinRequestContent = try codec.decode(content: encoded)

        #expect(decoded.profile?.name == "Bob")
        #expect(decoded.profile?.imageURL == nil)
    }

    @Test("Encode and decode with metadata")
    func encodeDecodeWithMetadata() throws {
        let metadata = [
            "deviceName": "Jarod's iPad",
            "confirmationCode": "482916",
        ]
        let original = JoinRequestContent(inviteSlug: "slug-789", metadata: metadata)

        let encoded = try codec.encode(content: original)
        let decoded: JoinRequestContent = try codec.decode(content: encoded)

        #expect(decoded.inviteSlug == "slug-789")
        #expect(decoded.metadata?["deviceName"] == "Jarod's iPad")
        #expect(decoded.metadata?["confirmationCode"] == "482916")
    }

    @Test("Encode and decode with all fields")
    func encodeDecodeAllFields() throws {
        let profile = JoinRequestProfile(name: "Charlie", imageURL: "https://example.com/charlie.png")
        let metadata = [
            "deviceName": "Charlie's iPhone",
            "confirmationCode": "123456",
            "customKey": "customValue",
        ]
        let original = JoinRequestContent(inviteSlug: "full-slug", profile: profile, metadata: metadata)

        let encoded = try codec.encode(content: original)
        let decoded: JoinRequestContent = try codec.decode(content: encoded)

        #expect(decoded.inviteSlug == "full-slug")
        #expect(decoded.profile?.name == "Charlie")
        #expect(decoded.profile?.imageURL == "https://example.com/charlie.png")
        #expect(decoded.metadata?["deviceName"] == "Charlie's iPhone")
        #expect(decoded.metadata?["confirmationCode"] == "123456")
        #expect(decoded.metadata?["customKey"] == "customValue")
    }

    @Test("Fallback returns invite slug")
    func fallbackReturnsSlug() throws {
        let content = JoinRequestContent(inviteSlug: "fallback-slug-test")
        let fallback = try codec.fallback(content: content)
        #expect(fallback == "fallback-slug-test")
    }

    @Test("Empty content throws error")
    func emptyContentThrows() {
        var encodedContent = EncodedContent()
        encodedContent.type = ContentTypeJoinRequest
        encodedContent.content = Data()

        #expect(throws: JoinRequestCodecError.emptyContent) {
            _ = try codec.decode(content: encodedContent) as JoinRequestContent
        }
    }

    @Test("Malformed JSON throws error")
    func malformedJSONThrows() {
        var encodedContent = EncodedContent()
        encodedContent.type = ContentTypeJoinRequest
        encodedContent.content = Data("not valid json".utf8)

        #expect(throws: Error.self) {
            _ = try codec.decode(content: encodedContent) as JoinRequestContent
        }
    }

    @Test("Missing invite slug throws error")
    func missingSlugThrows() {
        let json = Data("""
        {"profile": {"name": "Alice"}}
        """.utf8)

        var encodedContent = EncodedContent()
        encodedContent.type = ContentTypeJoinRequest
        encodedContent.content = json

        #expect(throws: Error.self) {
            _ = try codec.decode(content: encodedContent) as JoinRequestContent
        }
    }

    @Test("Forward compatibility ignores unknown fields")
    func forwardCompatibilityUnknownFields() throws {
        let json = Data("""
        {"inviteSlug": "compat-slug", "futureField": true, "anotherField": 42}
        """.utf8)

        var encodedContent = EncodedContent()
        encodedContent.type = ContentTypeJoinRequest
        encodedContent.content = json

        let decoded: JoinRequestContent = try codec.decode(content: encodedContent)
        #expect(decoded.inviteSlug == "compat-slug")
        #expect(decoded.profile == nil)
        #expect(decoded.metadata == nil)
    }

    @Test("Empty metadata is preserved")
    func emptyMetadata() throws {
        let original = JoinRequestContent(inviteSlug: "slug", metadata: [:])

        let encoded = try codec.encode(content: original)
        let decoded: JoinRequestContent = try codec.decode(content: encoded)

        #expect(decoded.metadata != nil)
        #expect(decoded.metadata?.isEmpty == true)
    }

    @Test("Special characters in metadata values")
    func specialCharactersInMetadata() throws {
        let metadata = [
            "deviceName": "Jarod's iPhone 📱",
            "note": "emoji 🎉 and \"quotes\"",
        ]
        let original = JoinRequestContent(inviteSlug: "slug", metadata: metadata)

        let encoded = try codec.encode(content: original)
        let decoded: JoinRequestContent = try codec.decode(content: encoded)

        #expect(decoded.metadata?["deviceName"] == "Jarod's iPhone 📱")
        #expect(decoded.metadata?["note"] == "emoji 🎉 and \"quotes\"")
    }

    @Test("Equatable conformance")
    func equatableConformance() {
        let a = JoinRequestContent(inviteSlug: "slug-a")
        let b = JoinRequestContent(inviteSlug: "slug-a")
        let c = JoinRequestContent(inviteSlug: "slug-c")

        #expect(a == b)
        #expect(a != c)
    }

    @Test("Profile equatable conformance")
    func profileEquatable() {
        let a = JoinRequestProfile(name: "Alice", imageURL: "https://example.com/a.jpg")
        let b = JoinRequestProfile(name: "Alice", imageURL: "https://example.com/a.jpg")
        let c = JoinRequestProfile(name: "Bob")

        #expect(a == b)
        #expect(a != c)
    }

    @Test("Long invite slug")
    func longInviteSlug() throws {
        let longSlug = String(repeating: "x", count: 5000)
        let original = JoinRequestContent(inviteSlug: longSlug)

        let encoded = try codec.encode(content: original)
        let decoded: JoinRequestContent = try codec.decode(content: encoded)

        #expect(decoded.inviteSlug == longSlug)
    }
}
