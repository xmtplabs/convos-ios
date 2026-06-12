import ConvosConnections
@testable import ConvosCore
import Foundation
import Testing
@preconcurrency import XMTPiOS

/// Wire-compat tests for `convos.org/capability_request_result/1.0`, focused
/// on the `stale_resource` status added for the connections-picker bundles
/// flow and on unknown-status forward compatibility. (Baseline round-trip
/// coverage lives in `CapabilityRequestResultCodecTests` in
/// CapabilityRequestCodecTests.swift.)
@Suite("CapabilityRequestResult codec — stale_resource + forward compat")
struct CapabilityRequestResultStaleResourceTests {
    private let codec: CapabilityRequestResultCodec = CapabilityRequestResultCodec()

    private func encodedContent(json: String) throws -> EncodedContent {
        var content = EncodedContent()
        content.type = ContentTypeCapabilityRequestResult
        content.content = try #require(json.data(using: .utf8))
        return content
    }

    @Test("pre-bundles payloads (no staleServices key) still decode")
    func decodesLegacyPayload() throws {
        let json = """
        {
          "version": 1,
          "requestId": "req-1",
          "status": "approved",
          "subject": "calendar",
          "capability": "read",
          "providers": ["device.calendar"]
        }
        """
        let result = try codec.decode(content: encodedContent(json: json))
        #expect(result.status == .approved)
        #expect(result.requestId == "req-1")
        #expect(result.providers == [ProviderID(rawValue: "device.calendar")])
        #expect(result.staleServices.isEmpty)
    }

    @Test("stale_resource decodes with its camelCase staleServices payload")
    func decodesStaleResource() throws {
        let json = """
        {
          "version": 1,
          "requestId": "req-2",
          "status": "stale_resource",
          "subject": "calendar",
          "capability": "read",
          "staleServices": [
            { "id": "googlecalendar", "expectedVersion": 3 }
          ]
        }
        """
        let result = try codec.decode(content: encodedContent(json: json))
        #expect(result.status == .staleResource)
        #expect(result.staleServices == [
            CapabilityRequestResult.StaleService(id: "googlecalendar", expectedVersion: 3),
        ])
    }

    @Test("an unrecognized status decodes to .unknown instead of throwing")
    func unknownStatusIsSafe() throws {
        let json = """
        {
          "version": 1,
          "requestId": "req-3",
          "status": "some_future_status",
          "subject": "calendar",
          "capability": "read"
        }
        """
        let result = try codec.decode(content: encodedContent(json: json))
        #expect(result.status == .unknown)
        #expect(result.requestId == "req-3")
    }

    @Test("encode/decode round-trips a stale_resource result")
    func roundTripsStaleResource() throws {
        let original = CapabilityRequestResult(
            requestId: "req-4",
            status: .staleResource,
            subject: .calendar,
            capability: .read,
            staleServices: [.init(id: "googlecalendar", expectedVersion: 7)]
        )
        let decoded = try codec.decode(content: codec.encode(content: original))
        #expect(decoded == original)

        // The status raw value on the wire is snake_case per the plan.
        let data = try codec.encode(content: original).content
        let object = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(object["status"] as? String == "stale_resource")
        let staleServices = try #require(object["staleServices"] as? [[String: Any]])
        #expect(staleServices.first?["expectedVersion"] as? Int == 7)
    }

    @Test("fallback copy exists for every status")
    func fallbackCoversAllStatuses() throws {
        for status in [CapabilityRequestResult.Status.approved, .denied, .cancelled, .staleResource, .unknown] {
            let result = CapabilityRequestResult(
                requestId: "req-5",
                status: status,
                subject: .calendar,
                capability: .read
            )
            let fallback = try codec.fallback(content: result)
            #expect(fallback?.isEmpty == false)
        }
    }
}
