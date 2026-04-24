@testable import ConvosCore
import Foundation
import Testing
import XMTPiOS

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

    @Test("Decoding a payload with a future version is rejected")
    func futureVersionRejected() throws {
        let futurePayload = """
        {
          "version": 2,
          "service": "google_calendar",
          "requestedByInboxId": "agent_inbox",
          "targetInboxId": "user_inbox",
          "reason": "future schema"
        }
        """
        var encoded = try codec.encode(content: sampleRequest)
        encoded.content = Data(futurePayload.utf8)

        #expect(throws: ConnectionGrantRequestCodecError.self) {
            _ = try codec.decode(content: encoded)
        }

        do {
            _ = try codec.decode(content: encoded)
            Issue.record("Expected unsupportedVersion error")
        } catch ConnectionGrantRequestCodecError.unsupportedVersion(let version) {
            #expect(version == 2)
        } catch {
            Issue.record("Expected unsupportedVersion, got \(error)")
        }
    }

    @Test("Reason longer than the cap is truncated on decode")
    func reasonTruncatedOnDecode() throws {
        let oversizedReason = String(repeating: "A", count: ConnectionGrantRequest.maxReasonLength + 250)
        let paddedRequest = ConnectionGrantRequest(
            service: "google_calendar",
            requestedByInboxId: "agent_inbox",
            targetInboxId: "user_inbox",
            reason: oversizedReason
        )

        // The public initializer also truncates — confirm that first so callers
        // building payloads locally can't bloat the DB either.
        #expect(paddedRequest.reason.count == ConnectionGrantRequest.maxReasonLength)

        // Craft a raw payload with the oversized reason and make sure decode still caps it.
        struct RawPayload: Encodable {
            let version: Int
            let service: String
            let requestedByInboxId: String
            let targetInboxId: String
            let reason: String
        }
        let rawData = try JSONEncoder().encode(RawPayload(
            version: ConnectionGrantRequest.supportedVersion,
            service: "google_calendar",
            requestedByInboxId: "agent_inbox",
            targetInboxId: "user_inbox",
            reason: oversizedReason
        ))

        var encoded = try codec.encode(content: sampleRequest)
        encoded.content = rawData
        let decoded = try codec.decode(content: encoded)

        #expect(decoded.reason.count == ConnectionGrantRequest.maxReasonLength)
        #expect(decoded.reason == String(repeating: "A", count: ConnectionGrantRequest.maxReasonLength))
    }

    @Test("validateConnectionGrantRequest rejects spoofed requestedByInboxId")
    func validateRejectsSpoofedSender() throws {
        let spoofed = ConnectionGrantRequest(
            service: "google_calendar",
            requestedByInboxId: "trusted_assistant_inbox",
            targetInboxId: "user_inbox",
            reason: "hostile reason"
        )

        #expect(throws: XMTPiOS.DecodedMessage.DecodedMessageDBRepresentationError.self) {
            try XMTPiOS.DecodedMessage.validateConnectionGrantRequest(
                spoofed,
                senderInboxId: "hostile_member_inbox",
                messageId: "msg-1"
            )
        }
    }

    @Test("validateConnectionGrantRequest passes when sender matches requestedByInboxId")
    func validateAcceptsMatchingSender() throws {
        let legitimate = ConnectionGrantRequest(
            service: "google_calendar",
            requestedByInboxId: "assistant_inbox",
            targetInboxId: "user_inbox",
            reason: "I can check your schedule."
        )

        try XMTPiOS.DecodedMessage.validateConnectionGrantRequest(
            legitimate,
            senderInboxId: "assistant_inbox",
            messageId: "msg-2"
        )
    }
}
