import Foundation

/// A snapshot of calendar events over a rolling window. `CalendarDataSource` emits one of
/// these on start and on every `EKEventStoreChanged` notification while the app is running.
///
/// EventKit has no true background delivery, so the host app relies on foreground /
/// `BGAppRefreshTask` wake-ups to pick up changes. The payload carries the whole window,
/// not a delta, so agents have a complete view of the user's upcoming schedule.
public struct CalendarPayload: Codable, Sendable, Equatable {
    public static let currentSchemaVersion: Int = 1

    public let schemaVersion: Int
    public let summary: String
    public let events: [CalendarEvent]
    public let rangeStart: Date
    public let rangeEnd: Date

    public init(
        schemaVersion: Int = Self.currentSchemaVersion,
        summary: String,
        events: [CalendarEvent],
        rangeStart: Date,
        rangeEnd: Date
    ) {
        self.schemaVersion = schemaVersion
        self.summary = summary
        self.events = events
        self.rangeStart = rangeStart
        self.rangeEnd = rangeEnd
    }
}

public struct CalendarEvent: Codable, Sendable, Equatable, Identifiable {
    public let id: String
    public let title: String?
    public let startDate: Date
    public let endDate: Date
    public let isAllDay: Bool
    public let location: String?
    public let notes: String?
    public let calendarTitle: String?
    public let status: CalendarEventStatus
    public let isRecurring: Bool

    public init(
        id: String,
        title: String?,
        startDate: Date,
        endDate: Date,
        isAllDay: Bool,
        location: String?,
        notes: String?,
        calendarTitle: String?,
        status: CalendarEventStatus,
        isRecurring: Bool
    ) {
        self.id = id
        self.title = title
        self.startDate = startDate
        self.endDate = endDate
        self.isAllDay = isAllDay
        self.location = location
        self.notes = notes
        self.calendarTitle = calendarTitle
        self.status = status
        self.isRecurring = isRecurring
    }
}

public enum CalendarEventStatus: String, Codable, Sendable {
    case confirmed
    case tentative
    case canceled
    case none
}
