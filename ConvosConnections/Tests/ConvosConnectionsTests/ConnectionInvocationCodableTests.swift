@testable import ConvosConnections
import Foundation
import Testing

@Suite("ConnectionInvocation coding")
struct ConnectionInvocationCodableTests {
    @Test("invocation round-trips through JSON")
    func invocationRoundTrips() throws {
        let invocation = ConnectionInvocation(
            id: UUID(uuidString: "00000000-0000-0000-0000-0000000000AA") ?? UUID(),
            invocationId: "agent-1-001",
            kind: .calendar,
            action: ConnectionAction(
                name: "create_event",
                arguments: [
                    "title": .string("Team sync"),
                    "startDate": .iso8601DateTime("2026-05-01T15:00:00-07:00"),
                    "endDate": .iso8601DateTime("2026-05-01T16:00:00-07:00"),
                    "timeZone": .string("America/Los_Angeles"),
                    "isAllDay": .bool(false),
                ]
            ),
            issuedAt: Date(timeIntervalSince1970: 1_700_000_000)
        )

        let data = try JSONEncoder().encode(invocation)
        let decoded = try JSONDecoder().decode(ConnectionInvocation.self, from: data)
        #expect(decoded == invocation)
    }

    @Test("result round-trips for every status case")
    func resultRoundTripsAllStatuses() throws {
        let statuses: [ConnectionInvocationResult.Status] = [
            .success,
            .capabilityNotEnabled,
            .capabilityRevoked,
            .requiresConfirmation,
            .authorizationDenied,
            .executionFailed,
            .unknownAction,
        ]
        for status in statuses {
            let result = ConnectionInvocationResult(
                invocationId: "req-\(status.rawValue)",
                kind: .calendar,
                actionName: "create_event",
                status: status,
                result: status == .success ? ["eventId": .string("evt-abc"), "calendarId": .string("cal-1")] : [:],
                errorMessage: status == .success ? nil : "test message"
            )
            let data = try JSONEncoder().encode(result)
            let decoded = try JSONDecoder().decode(ConnectionInvocationResult.self, from: data)
            #expect(decoded == result)
        }
    }

    @Test("ArgumentValue round-trips all cases including nested array")
    func argumentValueRoundTripsAllCases() throws {
        let values: [ArgumentValue] = [
            .string("hello"),
            .bool(true),
            .int(42),
            .double(3.14),
            .date(Date(timeIntervalSince1970: 1_700_000_000)),
            .iso8601DateTime("2026-05-01T15:00:00Z"),
            .enumValue("futureEvents"),
            .array([.string("a"), .int(1), .null, .array([.bool(false)])]),
            .null,
        ]
        for value in values {
            let data = try JSONEncoder().encode(value)
            let decoded = try JSONDecoder().decode(ArgumentValue.self, from: data)
            #expect(decoded == value)
        }
    }

    @Test("ActionSchema round-trips including recursive arrayOf parameter")
    func actionSchemaRoundTrips() throws {
        let schema = ActionSchema(
            kind: .calendar,
            actionName: "bulk_create",
            capability: .writeCreate,
            summary: "Create many events at once.",
            inputs: [
                ActionParameter(
                    name: "events",
                    type: .arrayOf(.string),
                    description: "list",
                    isRequired: true
                ),
                ActionParameter(
                    name: "mode",
                    type: .enumValue(allowed: ["fast", "careful"]),
                    description: "mode",
                    isRequired: false
                ),
            ],
            outputs: []
        )
        let data = try JSONEncoder().encode(schema)
        let decoded = try JSONDecoder().decode(ActionSchema.self, from: data)
        #expect(decoded == schema)
    }
}
