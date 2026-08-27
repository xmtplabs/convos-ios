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
            providerId: "composio.googlecalendar",
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
        {"version":1,"providerId":"composio.googlecalendar","action":"granted"}
        """#
        guard let data = json.data(using: .utf8) else {
            Issue.record("Failed to encode legacy JSON fixture")
            return
        }
        let decoded = try JSONDecoder().decode(ConnectionEvent.self, from: data)
        #expect(decoded.providerId == "composio.googlecalendar")
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

@Suite("Connection event writer")
struct ConnectionEventWriterTests {
    @Test("cloud grants preserve their routing fields and are not suppressed on retry")
    func cloudGrantsPreserveRoutingAndRetry() async throws {
        let writer = RecordingConnectionEventWriter()
        let providerId = ProviderID(rawValue: "composio.googledocs")

        try await writer.sendCloudGrantedEvents(
            providerIds: [providerId, ProviderID(rawValue: "device.calendar")],
            capability: nil,
            grantedToInboxIds: ["doc-agent"],
            in: "doc-dm"
        )
        try await writer.sendCloudGrantedEvents(
            providerIds: [providerId],
            capability: nil,
            grantedToInboxIds: ["doc-agent"],
            in: "doc-dm"
        )

        let expected = RecordingConnectionEventWriter.Grant(
            providerId: "composio.googledocs",
            capability: nil,
            grantedToInboxId: "doc-agent",
            conversationId: "doc-dm"
        )
        #expect(await writer.grants() == [expected, expected])
    }
}

private actor RecordingConnectionEventWriter: ConnectionEventWriterProtocol {
    struct Grant: Equatable, Sendable {
        let providerId: String
        let capability: ConnectionCapability?
        let grantedToInboxId: String?
        let conversationId: String
    }

    private var recordedGrants: [Grant] = []

    func grants() -> [Grant] {
        recordedGrants
    }

    func sendGranted(
        providerId: String,
        capability: ConnectionCapability?,
        grantedToInboxId: String?,
        in conversationId: String
    ) async throws {
        recordedGrants.append(Grant(
            providerId: providerId,
            capability: capability,
            grantedToInboxId: grantedToInboxId,
            conversationId: conversationId
        ))
    }

    func sendRevoked(
        providerId: String,
        capability: ConnectionCapability?,
        grantedToInboxId: String?,
        in conversationId: String
    ) async throws {}
}

@Suite("ConnectionMessageSummaryFormatter capability text")
struct ConnectionMessageSummaryFormatterCapabilityTests {
    @Test("granted device calendar brands the service regardless of capability")
    func grantedDeviceCalendarBrandsService() {
        for capability in [ConnectionCapability.read, .writeCreate, .writeUpdate, .writeDelete] {
            let event = ConnectionEvent(
                providerId: "device.calendar",
                action: .granted,
                capability: capability
            )
            let summary = ConnectionMessageSummaryFormatter.eventSummary(event)
            #expect(summary.text == "connected Apple Calendar", "unexpected text for \(capability)")
            #expect(summary.actor == .messageSender)
        }
    }

    @Test("granted cloud googlecalendar brands the service regardless of capability")
    func grantedCloudCalendarBrandsService() {
        for capability in [ConnectionCapability.read, .writeCreate, .writeUpdate, .writeDelete] {
            let event = ConnectionEvent(
                providerId: "composio.googlecalendar",
                action: .granted,
                capability: capability
            )
            let summary = ConnectionMessageSummaryFormatter.eventSummary(event)
            #expect(summary.text == "connected Google Calendar", "unexpected text for \(capability)")
            #expect(summary.actor == .messageSender)
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

    @Test("nil capability still brands the granted service")
    func nilCapabilityStillBrandsService() {
        let event = ConnectionEvent(
            providerId: "device.calendar",
            action: .granted,
            capability: nil
        )
        let summary = ConnectionMessageSummaryFormatter.eventSummary(event)
        #expect(summary.text == "connected Apple Calendar")
    }
}
