import Foundation

/// Static `ActionSchema` values published by `CalendarDataSink`. Declared as an enum
/// namespace so agents and the host app can reference them without constructing a sink.
public enum CalendarActionSchemas {
    public static let createEvent: ActionSchema = ActionSchema(
        kind: .calendar,
        actionName: "create_event",
        capability: .writeCreate,
        summary: "Create a new calendar event.",
        inputs: [
            ActionParameter(name: "title", type: .string, description: "Event title.", isRequired: true),
            ActionParameter(name: "startDate", type: .iso8601DateTime, description: "RFC 3339 start. Must include offset.", isRequired: true),
            ActionParameter(name: "endDate", type: .iso8601DateTime, description: "RFC 3339 end. Must include offset.", isRequired: true),
            ActionParameter(name: "timeZone", type: .string, description: "IANA timezone identifier, e.g. America/Los_Angeles.", isRequired: true),
            ActionParameter(name: "isAllDay", type: .bool, description: "Defaults to false.", isRequired: false),
            ActionParameter(name: "location", type: .string, description: "Free-form location string.", isRequired: false),
            ActionParameter(name: "notes", type: .string, description: "Event notes.", isRequired: false),
            ActionParameter(name: "calendarId", type: .string, description: "Target calendar identifier. If omitted, uses the user's default calendar.", isRequired: false),
            ActionParameter(name: "calendarTitle", type: .string, description: "Target calendar title. Collisions return executionFailed.", isRequired: false),
        ],
        outputs: [
            ActionParameter(name: "eventId", type: .string, description: "Newly-created event identifier.", isRequired: true),
            ActionParameter(name: "calendarId", type: .string, description: "Identifier of the calendar the event was written to.", isRequired: true),
        ]
    )

    public static let updateEvent: ActionSchema = ActionSchema(
        kind: .calendar,
        actionName: "update_event",
        capability: .writeUpdate,
        summary: "Update an existing calendar event.",
        inputs: [
            ActionParameter(name: "eventId", type: .string, description: "Identifier of the event to update.", isRequired: true),
            ActionParameter(name: "title", type: .string, description: "New title.", isRequired: false),
            ActionParameter(name: "startDate", type: .iso8601DateTime, description: "New start, RFC 3339 with offset.", isRequired: false),
            ActionParameter(name: "endDate", type: .iso8601DateTime, description: "New end, RFC 3339 with offset.", isRequired: false),
            ActionParameter(name: "timeZone", type: .string, description: "IANA timezone. Required if startDate or endDate is supplied.", isRequired: false),
            ActionParameter(name: "location", type: .string, description: "New location.", isRequired: false),
            ActionParameter(name: "notes", type: .string, description: "New notes.", isRequired: false),
            ActionParameter(name: "span", type: .enumValue(allowed: ["thisEvent", "futureEvents"]), description: "Recurring-event span. Defaults to futureEvents.", isRequired: false),
        ],
        outputs: [
            ActionParameter(name: "eventId", type: .string, description: "Updated event identifier.", isRequired: true),
        ]
    )

    public static let deleteEvent: ActionSchema = ActionSchema(
        kind: .calendar,
        actionName: "delete_event",
        capability: .writeDelete,
        summary: "Delete a calendar event.",
        inputs: [
            ActionParameter(name: "eventId", type: .string, description: "Identifier of the event to delete.", isRequired: true),
            ActionParameter(name: "span", type: .enumValue(allowed: ["thisEvent", "futureEvents"]), description: "Recurring-event span. Defaults to futureEvents.", isRequired: false),
        ],
        outputs: []
    )

    public static let createCalendar: ActionSchema = ActionSchema(
        kind: .calendar,
        actionName: "create_calendar",
        capability: .writeCreate,
        summary: "Create a new calendar.",
        inputs: [
            ActionParameter(name: "title", type: .string, description: "Display name of the new calendar.", isRequired: true),
            ActionParameter(name: "color", type: .string, description: "Optional hex color, e.g. \"#FF8800\" or \"#FF8800AA\". Falls back to the source's default.", isRequired: false),
            ActionParameter(
                name: "sourceType",
                type: .enumValue(allowed: ["iCloud", "local"]),
                description: "Where to host the calendar. Defaults to iCloud if available, falling back to local.",
                isRequired: false
            ),
        ],
        outputs: [
            ActionParameter(name: "calendarId", type: .string, description: "Identifier of the newly-created calendar.", isRequired: true),
        ]
    )

    public static let all: [ActionSchema] = [createEvent, updateEvent, deleteEvent, createCalendar]
}
