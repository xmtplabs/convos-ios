@testable import ConvosCore
import Foundation
import Testing
@preconcurrency import XMTPiOS

@Suite("ContextReply codec")
struct ContextReplyCodecTests {
    private let context = ContextReplyContext(
        id: "widget-1",
        title: "Weather",
        description: "Sunny, 24 degrees"
    )

    @Test("round-trips a text reply with its widget context")
    func roundTripText() throws {
        let codec = ContextReplyCodec()
        let contextReply = ContextReply(context: context, content: "Looks great!", contentType: ContentTypeText)

        let encoded = try codec.encode(content: contextReply)
        #expect(encoded.type == ContentTypeContextReply)

        let decoded = try codec.decode(content: encoded)
        #expect(decoded.context == context)
        #expect(decoded.contentType == ContentTypeText)
        #expect(decoded.content as? String == "Looks great!")
    }

    @Test("round-trips a remote-attachment reply, proving any content nests")
    func roundTripRemoteAttachment() throws {
        let codec = ContextReplyCodec()
        let remoteAttachment = try RemoteAttachment(
            url: "https://example.com/asset",
            contentDigest: "digest",
            secret: Data(repeating: 1, count: 32),
            salt: Data(repeating: 2, count: 32),
            nonce: Data(repeating: 3, count: 16),
            scheme: .https,
            contentLength: 10,
            filename: "photo.jpg"
        )
        let contextReply = ContextReply(
            context: context,
            content: remoteAttachment,
            contentType: ContentTypeRemoteAttachment
        )

        let encoded = try codec.encode(content: contextReply)
        let decoded = try codec.decode(content: encoded)
        #expect(decoded.context == context)
        #expect(decoded.contentType == ContentTypeRemoteAttachment)
        let decodedAttachment = try #require(decoded.content as? RemoteAttachment)
        #expect(decodedAttachment.url == "https://example.com/asset")
        #expect(decodedAttachment.filename == "photo.jpg")
    }

    @Test("fallback names the widget so clients without the codec see context")
    func fallback() throws {
        let codec = ContextReplyCodec()
        let contextReply = ContextReply(context: context, content: "Hi", contentType: ContentTypeText)
        #expect(try codec.fallback(content: contextReply) == "Replied to \"Weather\"")
    }

    @Test("pushes so all devices receive the reply")
    func pushes() throws {
        let codec = ContextReplyCodec()
        let contextReply = ContextReply(context: context, content: "Hi", contentType: ContentTypeText)
        #expect(try codec.shouldPush(content: contextReply) == true)
    }

    @Test("missing context parameter is rejected")
    func missingContextRejected() {
        let codec = ContextReplyCodec()
        var missing = EncodedContent()
        missing.type = ContentTypeContextReply
        missing.content = (try? TextCodec().encode(content: "Hi").serializedData()) ?? Data()
        #expect(throws: ContextReplyCodecError.self) {
            try codec.decode(content: missing)
        }
    }

    @Test("unsupported nested content type is rejected on encode")
    func unsupportedNestedRejected() {
        let codec = ContextReplyCodec()
        let contextReply = ContextReply(context: context, content: "Hi", contentType: ContentTypeReaction)
        #expect(throws: ContextReplyCodecError.self) {
            try codec.encode(content: contextReply)
        }
    }
}
