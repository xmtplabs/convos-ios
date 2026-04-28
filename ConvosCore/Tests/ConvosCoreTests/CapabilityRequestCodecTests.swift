@testable import ConvosCore
import ConvosConnections
import Foundation
import Testing
@preconcurrency import XMTPiOS

@Suite("CapabilityRequest codec")
struct CapabilityRequestCodecTests {
    @Test("round-trips through JSON")
    func roundTrip() throws {
        let codec = CapabilityRequestCodec()
        let request = CapabilityRequest(
            requestId: "req-1",
            subject: .calendar,
            capability: .read,
            rationale: "To summarize your week",
            preferredProviders: [ProviderID(rawValue: "device.calendar")]
        )
        let encoded = try codec.encode(content: request)
        #expect(encoded.type == ContentTypeCapabilityRequest)
        let decoded = try codec.decode(content: encoded)
        #expect(decoded == request)
    }

    @Test("nil preferredProviders round-trips as nil")
    func nilHintRoundTrips() throws {
        let codec = CapabilityRequestCodec()
        let request = CapabilityRequest(
            requestId: "req-1",
            subject: .calendar,
            capability: .read,
            rationale: "To summarize your week"
        )
        let decoded = try codec.decode(content: codec.encode(content: request))
        #expect(decoded.preferredProviders == nil)
    }

    @Test("rationale truncated at the cap")
    func rationaleTruncated() throws {
        let codec = CapabilityRequestCodec()
        let bloated = String(repeating: "x", count: CapabilityRequest.maxRationaleLength + 100)
        let request = CapabilityRequest(
            requestId: "req-1",
            subject: .calendar,
            capability: .read,
            rationale: bloated
        )
        let decoded = try codec.decode(content: codec.encode(content: request))
        #expect(decoded.rationale.count == CapabilityRequest.maxRationaleLength)
    }

    @Test("preferredProviders truncated at the cap")
    func providersTruncated() throws {
        let codec = CapabilityRequestCodec()
        let bloated = (0..<(CapabilityRequest.maxPreferredProviders + 5))
            .map { ProviderID(rawValue: "composio.x\($0)") }
        let request = CapabilityRequest(
            requestId: "req-1",
            subject: .calendar,
            capability: .read,
            rationale: "ok",
            preferredProviders: bloated
        )
        let decoded = try codec.decode(content: codec.encode(content: request))
        #expect(decoded.preferredProviders?.count == CapabilityRequest.maxPreferredProviders)
    }

    @Test("empty content rejected")
    func emptyContentRejected() {
        let codec = CapabilityRequestCodec()
        var empty = EncodedContent()
        empty.type = ContentTypeCapabilityRequest
        #expect(throws: CapabilityRequestCodecError.self) {
            try codec.decode(content: empty)
        }
    }

    @Test("future version rejected")
    func futureVersionRejected() throws {
        let codec = CapabilityRequestCodec()
        let request = CapabilityRequest(
            version: CapabilityRequest.supportedVersion + 1,
            requestId: "req-1",
            subject: .calendar,
            capability: .read,
            rationale: "ok"
        )
        let encoded = try codec.encode(content: request)
        #expect(throws: CapabilityRequestCodecError.self) {
            try codec.decode(content: encoded)
        }
    }

    @Test("fallback surfaces the subject")
    func fallback() throws {
        let codec = CapabilityRequestCodec()
        let request = CapabilityRequest(
            requestId: "req-1",
            subject: .fitness,
            capability: .read,
            rationale: "ok"
        )
        let fallback = try codec.fallback(content: request)
        #expect(fallback?.contains("fitness") == true)
    }

    @Test("shouldPush is false")
    func shouldPushFalse() throws {
        let codec = CapabilityRequestCodec()
        let request = CapabilityRequest(
            requestId: "req-1",
            subject: .calendar,
            capability: .read,
            rationale: "ok"
        )
        #expect(try codec.shouldPush(content: request) == false)
    }
}

@Suite("CapabilityRequestResult codec")
struct CapabilityRequestResultCodecTests {
    @Test("approved with single provider round-trips")
    func approvedSingle() throws {
        let codec = CapabilityRequestResultCodec()
        let result = CapabilityRequestResult(
            requestId: "req-1",
            status: .approved,
            subject: .calendar,
            capability: .read,
            providers: [ProviderID(rawValue: "device.calendar")]
        )
        let decoded = try codec.decode(content: codec.encode(content: result))
        #expect(decoded == result)
    }

    @Test("approved with federated providers round-trips")
    func approvedFederated() throws {
        let codec = CapabilityRequestResultCodec()
        let result = CapabilityRequestResult(
            requestId: "req-1",
            status: .approved,
            subject: .fitness,
            capability: .read,
            providers: [
                ProviderID(rawValue: "composio.strava"),
                ProviderID(rawValue: "composio.fitbit"),
            ]
        )
        let decoded = try codec.decode(content: codec.encode(content: result))
        #expect(decoded == result)
    }

    @Test("denied with no providers")
    func denied() throws {
        let codec = CapabilityRequestResultCodec()
        let result = CapabilityRequestResult(
            requestId: "req-1",
            status: .denied,
            subject: .calendar,
            capability: .read
        )
        let decoded = try codec.decode(content: codec.encode(content: result))
        #expect(decoded.status == .denied)
        #expect(decoded.providers.isEmpty)
    }

    @Test("cancelled status round-trips")
    func cancelled() throws {
        let codec = CapabilityRequestResultCodec()
        let result = CapabilityRequestResult(
            requestId: "req-1",
            status: .cancelled,
            subject: .calendar,
            capability: .read
        )
        let decoded = try codec.decode(content: codec.encode(content: result))
        #expect(decoded.status == .cancelled)
    }

    @Test("future version rejected")
    func futureVersionRejected() throws {
        let codec = CapabilityRequestResultCodec()
        let result = CapabilityRequestResult(
            version: CapabilityRequestResult.supportedVersion + 1,
            requestId: "req-1",
            status: .approved,
            subject: .calendar,
            capability: .read,
            providers: [ProviderID(rawValue: "device.calendar")]
        )
        let encoded = try codec.encode(content: result)
        #expect(throws: CapabilityRequestResultCodecError.self) {
            try codec.decode(content: encoded)
        }
    }

    @Test("providers truncated at the cap")
    func providersTruncated() throws {
        let codec = CapabilityRequestResultCodec()
        let bloated = (0..<(CapabilityRequestResult.maxProviders + 5))
            .map { ProviderID(rawValue: "composio.x\($0)") }
        let result = CapabilityRequestResult(
            requestId: "req-1",
            status: .approved,
            subject: .fitness,
            capability: .read,
            providers: bloated
        )
        let decoded = try codec.decode(content: codec.encode(content: result))
        #expect(decoded.providers.count == CapabilityRequestResult.maxProviders)
    }

    @Test("fallback differentiates by status")
    func fallbackByStatus() throws {
        let codec = CapabilityRequestResultCodec()
        for status in [CapabilityRequestResult.Status.approved, .denied, .cancelled] {
            let result = CapabilityRequestResult(
                requestId: "req-1",
                status: status,
                subject: .calendar,
                capability: .read,
                providers: status == .approved ? [ProviderID(rawValue: "device.calendar")] : []
            )
            let fallback = try codec.fallback(content: result)
            #expect(fallback?.contains("calendar") == true)
        }
    }
}
