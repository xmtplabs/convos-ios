import ConvosConnections
@testable import ConvosCore
import Foundation
import Testing

@Suite("ConnectionEvent codec")
struct ConnectionEventCodecTests {
    @Test("round-trips with capability")
    func roundTripsWithCapability() throws {
        let codec = ConnectionEventCodec()
        let event = ConnectionEvent(
            providerId: "composio.google_calendar",
            action: .granted,
            capability: .writeCreate
        )
        let encoded = try codec.encode(content: event)
        #expect(encoded.type == ContentTypeConnectionEvent)
        let decoded = try codec.decode(content: encoded)
        #expect(decoded == event)
        #expect(decoded.capability == .writeCreate)
    }

    @Test("round-trips without capability")
    func roundTripsWithoutCapability() throws {
        let codec = ConnectionEventCodec()
        let event = ConnectionEvent(
            providerId: "device.calendar",
            action: .granted
        )
        let encoded = try codec.encode(content: event)
        let decoded = try codec.decode(content: encoded)
        #expect(decoded.capability == nil)
        #expect(decoded == event)
    }

    @Test("decodes legacy payload missing capability field")
    func decodesLegacyPayload() throws {
        let json = #"""
        {"version":1,"providerId":"composio.google_calendar","action":"granted"}
        """#
        guard let data = json.data(using: .utf8) else {
            Issue.record("Failed to encode legacy JSON fixture")
            return
        }
        let decoded = try JSONDecoder().decode(ConnectionEvent.self, from: data)
        #expect(decoded.providerId == "composio.google_calendar")
        #expect(decoded.action == .granted)
        #expect(decoded.capability == nil)
    }

    @Test("omits capability key when nil")
    func omitsCapabilityKeyWhenNil() throws {
        let event = ConnectionEvent(providerId: "device.calendar", action: .granted)
        let data = try JSONEncoder().encode(event)
        guard let json = String(data: data, encoding: .utf8) else {
            Issue.record("Failed to decode JSON output")
            return
        }
        #expect(!json.contains("capability"))
    }
}

@Suite("ConnectionMessageSummaryFormatter capability text")
struct ConnectionMessageSummaryFormatterCapabilityTests {
    @Test("granted device calendar varies by capability")
    func grantedDeviceCalendarVariesByCapability() {
        let cases: [(ConnectionCapability, String)] = [
            (.read, "can read calendar events"),
            (.writeCreate, "can create calendar events"),
            (.writeUpdate, "can edit calendar events"),
            (.writeDelete, "can delete calendar events"),
        ]
        for (capability, expected) in cases {
            let event = ConnectionEvent(
                providerId: "device.calendar",
                action: .granted,
                capability: capability
            )
            let summary = ConnectionMessageSummaryFormatter.eventSummary(event)
            #expect(summary.text == expected, "expected \(expected) for \(capability)")
        }
    }

    @Test("granted cloud google_calendar varies by capability")
    func grantedCloudCalendarVariesByCapability() {
        let cases: [(ConnectionCapability, String)] = [
            (.read, "can read calendar events"),
            (.writeCreate, "can create calendar events"),
            (.writeUpdate, "can edit calendar events"),
            (.writeDelete, "can delete calendar events"),
        ]
        for (capability, expected) in cases {
            let event = ConnectionEvent(
                providerId: "composio.google_calendar",
                action: .granted,
                capability: capability
            )
            let summary = ConnectionMessageSummaryFormatter.eventSummary(event)
            #expect(summary.text == expected, "expected \(expected) for \(capability)")
        }
    }

    @Test("revoked device calendar varies by capability")
    func revokedDeviceCalendarVariesByCapability() {
        let cases: [(ConnectionCapability, String)] = [
            (.read, "Calendar events read access removed"),
            (.writeCreate, "Calendar events create access removed"),
            (.writeUpdate, "Calendar events update access removed"),
            (.writeDelete, "Calendar events delete access removed"),
        ]
        for (capability, expected) in cases {
            let event = ConnectionEvent(
                providerId: "device.calendar",
                action: .revoked,
                capability: capability
            )
            let summary = ConnectionMessageSummaryFormatter.eventSummary(event)
            #expect(summary.text == expected, "expected \(expected) for \(capability)")
        }
    }

    @Test("nil capability falls back to legacy text")
    func nilCapabilityFallsBackToLegacyText() {
        let event = ConnectionEvent(
            providerId: "device.calendar",
            action: .granted,
            capability: nil
        )
        let summary = ConnectionMessageSummaryFormatter.eventSummary(event)
        #expect(summary.text == "has access to calendar data")
    }
}
