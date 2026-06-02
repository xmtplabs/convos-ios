@testable import ConvosCore
import Foundation
import Testing
@preconcurrency import XMTPiOS

@Suite("BuilderBundleManifest codec")
struct BuilderBundleManifestCodecTests {
    @Test("round-trips message ids through JSON")
    func roundTrip() throws {
        let codec = BuilderBundleManifestCodec()
        let manifest = BuilderBundleManifest(messageIds: ["m1", "m2", "m3"])
        let encoded = try codec.encode(content: manifest)
        #expect(encoded.type == ContentTypeBuilderBundleManifest)
        let decoded = try codec.decode(content: encoded)
        #expect(decoded == manifest)
        #expect(decoded.messageIds == ["m1", "m2", "m3"])
    }

    @Test("empty message-id list round-trips")
    func emptyListRoundTrips() throws {
        let codec = BuilderBundleManifestCodec()
        let decoded = try codec.decode(content: codec.encode(content: BuilderBundleManifest(messageIds: [])))
        #expect(decoded.messageIds.isEmpty)
    }

    @Test("empty content is rejected")
    func emptyContentRejected() {
        let codec = BuilderBundleManifestCodec()
        var empty = EncodedContent()
        empty.type = ContentTypeBuilderBundleManifest
        #expect(throws: BuilderBundleManifestCodecError.self) {
            try codec.decode(content: empty)
        }
    }

    @Test("invalid JSON is rejected")
    func invalidJSONRejected() {
        let codec = BuilderBundleManifestCodec()
        var bad = EncodedContent()
        bad.type = ContentTypeBuilderBundleManifest
        bad.content = Data("not json".utf8)
        #expect(throws: BuilderBundleManifestCodecError.self) {
            try codec.decode(content: bad)
        }
    }

    @Test("is a silent control message: no push, no fallback")
    func silent() throws {
        let codec = BuilderBundleManifestCodec()
        let manifest = BuilderBundleManifest(messageIds: ["m1"])
        #expect(try codec.shouldPush(content: manifest) == false)
        #expect(try codec.fallback(content: manifest) == nil)
    }
}
