@testable import ConvosConnections
import Testing

@Suite("Calendar action schemas")
struct CalendarActionSchemasTests {
    @Test("publishes four actions")
    func publishesFourActions() {
        let schemas = CalendarActionSchemas.all
        #expect(schemas.count == 4)
        let names = Set(schemas.map(\.actionName))
        #expect(names == ["create_event", "update_event", "delete_event", "create_calendar"])
    }

    @Test("create_calendar requires title")
    func createCalendarRequiredInputs() {
        let inputs = CalendarActionSchemas.createCalendar.inputs
        let required = inputs.filter(\.isRequired).map(\.name)
        #expect(required == ["title"])
    }

    @Test("create_calendar exposes calendarId output")
    func createCalendarOutputs() {
        let outputs = CalendarActionSchemas.createCalendar.outputs
        #expect(outputs.map(\.name) == ["calendarId"])
    }

    @Test("create_calendar sourceType is constrained to iCloud and local")
    func createCalendarSourceTypeAllowedValues() {
        let sourceType = CalendarActionSchemas.createCalendar.inputs.first(where: { $0.name == "sourceType" })
        guard case .enumValue(let allowed) = sourceType?.type else {
            Issue.record("Expected sourceType to be .enumValue, got \(String(describing: sourceType?.type))")
            return
        }
        #expect(allowed == ["iCloud", "local"])
    }

    @Test("create_calendar uses writeCreate capability")
    func createCalendarCapability() {
        #expect(CalendarActionSchemas.createCalendar.capability == .writeCreate)
    }
}
