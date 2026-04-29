import Foundation
#if canImport(EventKit)
@preconcurrency import EventKit
#endif

/// Translates `EKEvent` into the package's transport-friendly `CalendarEvent` value.
///
/// Kept separate from `CalendarDataSource` so the mapping is isolated for review and
/// easier to unit-test on iOS. The package-level tests don't cover this directly because
/// `EKEvent` can't be constructed without an `EKEventStore`.
enum CalendarEventMapper {
    #if canImport(EventKit)
    static func map(_ event: EKEvent) -> CalendarEvent {
        CalendarEvent(
            id: event.calendarItemIdentifier,
            title: event.title,
            startDate: event.startDate ?? Date(),
            endDate: event.endDate ?? event.startDate ?? Date(),
            isAllDay: event.isAllDay,
            location: event.location,
            notes: event.notes,
            calendarTitle: event.calendar?.title,
            status: map(ekStatus: event.status),
            isRecurring: event.hasRecurrenceRules
        )
    }

    private static func map(ekStatus: EKEventStatus) -> CalendarEventStatus {
        switch ekStatus {
        case .confirmed: return .confirmed
        case .tentative: return .tentative
        case .canceled: return .canceled
        case .none: return .none
        @unknown default: return .none
        }
    }
    #endif
}
