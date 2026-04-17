import ConvosConnections
@testable import ConvosConnectionsXMTP
import Foundation
import Testing
@preconcurrency import XMTPiOS

@Suite("Connection codec round-trip")
struct ConnectionCodecRoundTripTests {
    @Test("payload round-trips")
    func payloadRoundTrips() throws {
        let codec = ConnectionPayloadCodec()
        let now = Date()
        let payload = ConnectionPayload(
            source: .calendar,
            body: .calendar(CalendarPayload(
                summary: "2 events today",
                events: [],
                rangeStart: now,
                rangeEnd: now
            ))
        )
        let encoded = try codec.encode(content: payload)
        #expect(encoded.type == ContentTypeConnectionPayload)
        let decoded = try codec.decode(content: encoded)
        #expect(decoded.source == payload.source)
        #expect(decoded.summary == payload.summary)
    }

    @Test("invocation round-trips")
    func invocationRoundTrips() throws {
        let codec = ConnectionInvocationCodec()
        let invocation = ConnectionInvocation(
            invocationId: "agent-1-001",
            kind: .contacts,
            action: ConnectionAction(
                name: "create_contact",
                arguments: [
                    "givenName": .string("Jane"),
                    "email": .string("jane@example.com"),
                ]
            )
        )
        let encoded = try codec.encode(content: invocation)
        #expect(encoded.type == ContentTypeConnectionInvocation)
        let decoded = try codec.decode(content: encoded)
        #expect(decoded == invocation)
    }

    @Test("result round-trips")
    func resultRoundTrips() throws {
        let codec = ConnectionInvocationResultCodec()
        let result = ConnectionInvocationResult(
            invocationId: "agent-1-001",
            kind: .contacts,
            actionName: "create_contact",
            status: .success,
            result: ["contactId": .string("ABC123")]
        )
        let encoded = try codec.encode(content: result)
        #expect(encoded.type == ContentTypeConnectionInvocationResult)
        let decoded = try codec.decode(content: encoded)
        #expect(decoded == result)
    }

    @Test("fallbacks are plain, no emoji")
    func fallbacks() throws {
        #expect(try ConnectionPayloadCodec().fallback(content: .init(source: .calendar, body: .calendar(.init(summary: "", events: [], rangeStart: Date(), rangeEnd: Date())))) == "Connection event")
        #expect(try ConnectionInvocationCodec().fallback(content: .init(invocationId: "x", kind: .contacts, action: .init(name: "y", arguments: [:]))) == "Connection invocation")
        #expect(try ConnectionInvocationResultCodec().fallback(content: .init(invocationId: "x", kind: .contacts, actionName: "y", status: .success)) == "Connection result")
    }

    @Test("all three codecs skip push")
    func shouldPush() throws {
        #expect(try ConnectionPayloadCodec().shouldPush(content: .init(source: .calendar, body: .calendar(.init(summary: "", events: [], rangeStart: Date(), rangeEnd: Date())))) == false)
        #expect(try ConnectionInvocationCodec().shouldPush(content: .init(invocationId: "x", kind: .contacts, action: .init(name: "y", arguments: [:]))) == false)
        #expect(try ConnectionInvocationResultCodec().shouldPush(content: .init(invocationId: "x", kind: .contacts, actionName: "y", status: .success)) == false)
    }

    @Test("empty content decode throws")
    func emptyContent() {
        var empty = EncodedContent()
        empty.type = ContentTypeConnectionInvocation
        #expect(throws: ConnectionInvocationCodecError.emptyContent) {
            try ConnectionInvocationCodec().decode(content: empty)
        }
    }
}
