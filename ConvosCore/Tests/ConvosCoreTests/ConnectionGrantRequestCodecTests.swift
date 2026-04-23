@testable import ConvosCore
import Foundation
import Testing

@Suite("ConnectionGrantRequestCodec Tests")
struct ConnectionGrantRequestCodecTests {
    let codec: ConnectionGrantRequestCodec = ConnectionGrantRequestCodec()

    private let sampleRequest: ConnectionGrantRequest = ConnectionGrantRequest(
        service: "google_calendar",
        requestedByInboxId: "agent_inbox",
        targetInboxId: "user_inbox",
        reason: "I can check your schedule."
    )

    @Test("Round-trips all fields through encode/decode")
    func roundTrip() throws {
        let encoded = try codec.encode(content: sampleRequest)
        let decoded = try codec.decode(content: encoded)

        #expect(decoded == sampleRequest)
        #expect(decoded.version == 1)
        #expect(decoded.service == "google_calendar")
        #expect(decoded.requestedByInboxId == "agent_inbox")
        #expect(decoded.targetInboxId == "user_inbox")
        #expect(decoded.reason == "I can check your schedule.")
    }

    @Test("ContentTypeID matches the runtime's expected identifier")
    func contentTypeID() {
        #expect(ContentTypeConnectionGrantRequest.authorityID == "convos.org")
        #expect(ContentTypeConnectionGrantRequest.typeID == "connection_grant_request")
        #expect(ContentTypeConnectionGrantRequest.versionMajor == 1)
        #expect(ContentTypeConnectionGrantRequest.versionMinor == 0)
    }

    @Test("shouldPush is false — cards surface without extra notification")
    func shouldNotPush() throws {
        #expect(try codec.shouldPush(content: sampleRequest) == false)
    }

    @Test("Fallback text mentions the service for pre-codec clients")
    func fallback() throws {
        let text = try #require(try codec.fallback(content: sampleRequest))
        #expect(text.contains("google_calendar"))
    }

    @Test("Decoding empty content throws")
    func emptyContentThrows() throws {
        var empty = try codec.encode(content: sampleRequest)
        empty.content = Data()
        #expect(throws: ConnectionGrantRequestCodecError.self) {
            _ = try codec.decode(content: empty)
        }
    }

    @Test("Decoding invalid JSON throws")
    func invalidContentThrows() throws {
        var bogus = try codec.encode(content: sampleRequest)
        bogus.content = Data([0x00, 0x01, 0x02, 0x03])
        #expect(throws: ConnectionGrantRequestCodecError.self) {
            _ = try codec.decode(content: bogus)
        }
    }
}
