import ConvosConnections
@testable import ConvosConnectionsXMTP
import Foundation
import Testing

@Suite("XMTP connection delivery")
struct XMTPConnectionDeliveryTests {
    @Test("payload delivery calls the conversation lookup")
    func payloadCallsLookup() async throws {
        let counter = LookupCounter()
        let delivery = XMTPConnectionDelivery { conversationId in
            await counter.record(conversationId)
            return nil
        }
        let payload = ConnectionPayload(
            source: .calendar,
            body: .calendar(CalendarPayload(
                summary: "",
                events: [],
                rangeStart: Date(),
                rangeEnd: Date()
            ))
        )
        await #expect(throws: XMTPConnectionDeliveryError.self) {
            try await delivery.deliver(payload, to: "conv-x")
        }
        #expect(await counter.observedIds() == ["conv-x"])
    }

    @Test("result delivery throws conversationNotFound when lookup returns nil")
    func resultThrowsOnMissing() async throws {
        let delivery = XMTPConnectionDelivery { _ in nil }
        let result = ConnectionInvocationResult(
            invocationId: "x",
            kind: .calendar,
            actionName: "create_event",
            status: .success
        )
        await #expect(throws: XMTPConnectionDeliveryError.self) {
            try await delivery.deliver(result, to: "missing")
        }
    }
}

private actor LookupCounter {
    private var ids: [String] = []

    func record(_ id: String) { ids.append(id) }
    func observedIds() -> [String] { ids }
}
