import Foundation
#if canImport(EventKit)
@preconcurrency import EventKit
#endif

/// Write-side counterpart to `CalendarDataSource`.
///
/// Supports three actions (see `CalendarActionSchemas`): `create_event`, `update_event`,
/// `delete_event`. Enforces the PRD-mandated strict timezone rule — every datetime input
/// must be paired with an explicit IANA `timeZone` identifier. Missing or ambiguous zones
/// return `executionFailed` rather than silently falling back to the device zone.
///
/// Owns its own `EKEventStore`; does not share with `CalendarDataSource`. Keeping the
/// stores separate means read-side observer tokens don't cross into write-side auth
/// changes. The cost is an extra `EKEventStore` instance in memory, which is trivial.
public final class CalendarDataSink: DataSink, @unchecked Sendable {
    public let kind: ConnectionKind = .calendar

    public init() {
        #if canImport(EventKit)
        self.state = StateBox()
        #endif
    }

    public func actionSchemas() async -> [ActionSchema] {
        CalendarActionSchemas.all
    }

    #if canImport(EventKit)
    private let state: StateBox

    public func authorizationStatus() async -> ConnectionAuthorizationStatus {
        let status = EKEventStore.authorizationStatus(for: .event)
        return CalendarDataSource.map(ekStatus: status)
    }

    @discardableResult
    public func requestAuthorization() async throws -> ConnectionAuthorizationStatus {
        let store = EKEventStore()
        _ = try await store.requestFullAccessToEvents()
        return await authorizationStatus()
    }

    public func invoke(_ invocation: ConnectionInvocation) async -> ConnectionInvocationResult {
        await state.invoke(invocation)
    }

    private actor StateBox {
        private let store: EKEventStore = EKEventStore()

        private enum Resolution<Value> {
            case success(Value)
            case failure(String)
        }

        func invoke(_ invocation: ConnectionInvocation) async -> ConnectionInvocationResult {
            let actionName = invocation.action.name
            switch actionName {
            case CalendarActionSchemas.createEvent.actionName:
                return createEvent(invocation)
            case CalendarActionSchemas.updateEvent.actionName:
                return updateEvent(invocation)
            case CalendarActionSchemas.deleteEvent.actionName:
                return deleteEvent(invocation)
            case CalendarActionSchemas.createCalendar.actionName:
                return createCalendar(invocation)
            default:
                return Self.makeResult(
                    for: invocation,
                    status: .unknownAction,
                    errorMessage: "Calendar sink does not know action '\(actionName)'."
                )
            }
        }

        private func createEvent(_ invocation: ConnectionInvocation) -> ConnectionInvocationResult {
            let args = invocation.action.arguments

            guard EKEventStore.authorizationStatus(for: .event) == .fullAccess else {
                return Self.makeResult(for: invocation, status: .authorizationDenied, errorMessage: "Calendar access is not granted.")
            }

            guard let title = args["title"]?.stringValue, !title.isEmpty else {
                return Self.makeResult(for: invocation, status: .executionFailed, errorMessage: "Missing required argument 'title'.")
            }
            guard let startRaw = args["startDate"]?.iso8601Value else {
                return Self.makeResult(for: invocation, status: .executionFailed, errorMessage: "Missing required argument 'startDate'.")
            }
            guard let endRaw = args["endDate"]?.iso8601Value else {
                return Self.makeResult(for: invocation, status: .executionFailed, errorMessage: "Missing required argument 'endDate'.")
            }
            guard let zoneId = args["timeZone"]?.stringValue, let timeZone = TimeZone(identifier: zoneId) else {
                return Self.makeResult(for: invocation, status: .executionFailed, errorMessage: "Missing or invalid IANA 'timeZone'.")
            }
            guard let startDate = Self.parseStrictISO8601(startRaw) else {
                return Self.makeResult(for: invocation, status: .executionFailed, errorMessage: "Could not parse 'startDate' as RFC 3339 with offset.")
            }
            guard let endDate = Self.parseStrictISO8601(endRaw) else {
                return Self.makeResult(for: invocation, status: .executionFailed, errorMessage: "Could not parse 'endDate' as RFC 3339 with offset.")
            }

            let calendarResult = resolveCalendar(
                calendarId: args["calendarId"]?.stringValue,
                calendarTitle: args["calendarTitle"]?.stringValue
            )
            let targetCalendar: EKCalendar
            switch calendarResult {
            case .success(let value):
                targetCalendar = value
            case .failure(let message):
                return Self.makeResult(for: invocation, status: .executionFailed, errorMessage: message)
            }

            let event = EKEvent(eventStore: store)
            event.title = title
            event.startDate = startDate
            event.endDate = endDate
            event.timeZone = timeZone
            event.isAllDay = args["isAllDay"]?.boolValue ?? false
            event.location = args["location"]?.stringValue
            event.notes = args["notes"]?.stringValue
            event.calendar = targetCalendar

            do {
                try store.save(event, span: .thisEvent, commit: true)
            } catch {
                return Self.makeResult(for: invocation, status: .executionFailed, errorMessage: error.localizedDescription)
            }

            return Self.makeResult(
                for: invocation,
                status: .success,
                result: [
                    "eventId": .string(event.calendarItemIdentifier),
                    "calendarId": .string(targetCalendar.calendarIdentifier),
                ]
            )
        }

        private func updateEvent(_ invocation: ConnectionInvocation) -> ConnectionInvocationResult {
            let args = invocation.action.arguments

            guard EKEventStore.authorizationStatus(for: .event) == .fullAccess else {
                return Self.makeResult(for: invocation, status: .authorizationDenied, errorMessage: "Calendar access is not granted.")
            }
            guard let eventId = args["eventId"]?.stringValue else {
                return Self.makeResult(for: invocation, status: .executionFailed, errorMessage: "Missing required argument 'eventId'.")
            }
            guard let event = store.event(withIdentifier: eventId) else {
                return Self.makeResult(for: invocation, status: .executionFailed, errorMessage: "Event not found for id '\(eventId)'.")
            }

            let startRaw = args["startDate"]?.iso8601Value
            let endRaw = args["endDate"]?.iso8601Value
            let zoneId = args["timeZone"]?.stringValue

            if startRaw != nil || endRaw != nil {
                guard let zoneId, let timeZone = TimeZone(identifier: zoneId) else {
                    return Self.makeResult(for: invocation, status: .executionFailed, errorMessage: "Missing or invalid IANA 'timeZone'. Required when updating start or end.")
                }
                event.timeZone = timeZone
                if let startRaw {
                    guard let parsed = Self.parseStrictISO8601(startRaw) else {
                        return Self.makeResult(for: invocation, status: .executionFailed, errorMessage: "Could not parse 'startDate'.")
                    }
                    event.startDate = parsed
                }
                if let endRaw {
                    guard let parsed = Self.parseStrictISO8601(endRaw) else {
                        return Self.makeResult(for: invocation, status: .executionFailed, errorMessage: "Could not parse 'endDate'.")
                    }
                    event.endDate = parsed
                }
            }

            if let newTitle = args["title"]?.stringValue {
                event.title = newTitle
            }
            if let newLocation = args["location"]?.stringValue {
                event.location = newLocation
            }
            if let newNotes = args["notes"]?.stringValue {
                event.notes = newNotes
            }

            let spanResult = Self.resolveSpan(args["span"])
            let span: EKSpan
            switch spanResult {
            case .success(let value):
                span = value
            case .failure(let message):
                return Self.makeResult(for: invocation, status: .executionFailed, errorMessage: message)
            }

            do {
                try store.save(event, span: span, commit: true)
            } catch {
                return Self.makeResult(for: invocation, status: .executionFailed, errorMessage: error.localizedDescription)
            }

            return Self.makeResult(
                for: invocation,
                status: .success,
                result: ["eventId": .string(event.calendarItemIdentifier)]
            )
        }

        private func deleteEvent(_ invocation: ConnectionInvocation) -> ConnectionInvocationResult {
            let args = invocation.action.arguments

            guard EKEventStore.authorizationStatus(for: .event) == .fullAccess else {
                return Self.makeResult(for: invocation, status: .authorizationDenied, errorMessage: "Calendar access is not granted.")
            }
            guard let eventId = args["eventId"]?.stringValue else {
                return Self.makeResult(for: invocation, status: .executionFailed, errorMessage: "Missing required argument 'eventId'.")
            }
            guard let event = store.event(withIdentifier: eventId) else {
                return Self.makeResult(for: invocation, status: .executionFailed, errorMessage: "Event not found for id '\(eventId)'.")
            }

            let spanResult = Self.resolveSpan(args["span"])
            let span: EKSpan
            switch spanResult {
            case .success(let value):
                span = value
            case .failure(let message):
                return Self.makeResult(for: invocation, status: .executionFailed, errorMessage: message)
            }

            do {
                try store.remove(event, span: span, commit: true)
            } catch {
                return Self.makeResult(for: invocation, status: .executionFailed, errorMessage: error.localizedDescription)
            }

            return Self.makeResult(for: invocation, status: .success)
        }

        private func resolveCalendar(calendarId: String?, calendarTitle: String?) -> Resolution<EKCalendar> {
            if let calendarId {
                if let calendar = store.calendar(withIdentifier: calendarId) {
                    return .success(calendar)
                }
                return .failure("Calendar not found for id '\(calendarId)'.")
            }
            if let calendarTitle {
                let matches = store.calendars(for: .event).filter { $0.title == calendarTitle }
                if matches.count == 1, let calendar = matches.first {
                    return .success(calendar)
                }
                if matches.isEmpty {
                    return .failure("No calendar found with title '\(calendarTitle)'.")
                }
                return .failure("Multiple calendars named '\(calendarTitle)'; disambiguate by id.")
            }
            if let defaultCalendar = store.defaultCalendarForNewEvents {
                return .success(defaultCalendar)
            }
            return .failure("No default calendar for new events is configured.")
        }

        private func createCalendar(_ invocation: ConnectionInvocation) -> ConnectionInvocationResult {
            let args = invocation.action.arguments

            guard EKEventStore.authorizationStatus(for: .event) == .fullAccess else {
                return Self.makeResult(for: invocation, status: .authorizationDenied, errorMessage: "Calendar access is not granted.")
            }

            guard let title = args["title"]?.stringValue, !title.isEmpty else {
                return Self.makeResult(for: invocation, status: .executionFailed, errorMessage: "Missing required argument 'title'.")
            }

            let source: EKSource
            switch resolveSource(preferred: args["sourceType"]?.enumRawValue) {
            case .success(let value):
                source = value
            case .failure(let message):
                return Self.makeResult(for: invocation, status: .executionFailed, errorMessage: message)
            }

            let calendar = EKCalendar(for: .event, eventStore: store)
            calendar.title = title
            calendar.source = source

            if let raw = args["color"]?.stringValue {
                guard let cgColor = Self.parseHexColor(raw) else {
                    return Self.makeResult(for: invocation, status: .executionFailed, errorMessage: "Could not parse 'color' as a hex string. Expected #RRGGBB or #RRGGBBAA.")
                }
                calendar.cgColor = cgColor
            }

            do {
                try store.saveCalendar(calendar, commit: true)
            } catch {
                return Self.makeResult(for: invocation, status: .executionFailed, errorMessage: "Failed to save calendar: \(error.localizedDescription)")
            }

            return Self.makeResult(
                for: invocation,
                status: .success,
                result: ["calendarId": .string(calendar.calendarIdentifier)]
            )
        }

        private func resolveSource(preferred: String?) -> Resolution<EKSource> {
            let sources = store.sources
            let iCloud = sources.first { $0.sourceType == .calDAV && $0.title.localizedCaseInsensitiveContains("icloud") }
            let local = sources.first { $0.sourceType == .local }

            switch preferred {
            case "iCloud":
                guard let source = iCloud else {
                    return .failure("No iCloud calendar source is configured on this device.")
                }
                return .success(source)
            case "local":
                guard let source = local else {
                    return .failure("No local calendar source is available.")
                }
                return .success(source)
            case .some(let other):
                return .failure("Unknown 'sourceType' value '\(other)'. Allowed: iCloud, local.")
            case .none:
                if let source = iCloud ?? local {
                    return .success(source)
                }
                return .failure("No writable calendar source (iCloud or local) is available on this device.")
            }
        }

        private static func parseHexColor(_ raw: String) -> CGColor? {
            var hex = raw
            if hex.hasPrefix("#") { hex.removeFirst() }
            guard hex.count == 6 || hex.count == 8 else { return nil }
            var value: UInt64 = 0
            guard Scanner(string: hex).scanHexInt64(&value) else { return nil }
            let red: CGFloat
            let green: CGFloat
            let blue: CGFloat
            let alpha: CGFloat
            if hex.count == 6 {
                red = CGFloat((value >> 16) & 0xFF) / 255.0
                green = CGFloat((value >> 8) & 0xFF) / 255.0
                blue = CGFloat(value & 0xFF) / 255.0
                alpha = 1.0
            } else {
                red = CGFloat((value >> 24) & 0xFF) / 255.0
                green = CGFloat((value >> 16) & 0xFF) / 255.0
                blue = CGFloat((value >> 8) & 0xFF) / 255.0
                alpha = CGFloat(value & 0xFF) / 255.0
            }
            let space = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
            return CGColor(colorSpace: space, components: [red, green, blue, alpha])
        }

        private static func resolveSpan(_ argument: ArgumentValue?) -> Resolution<EKSpan> {
            guard let argument else { return .success(.futureEvents) }
            let raw: String?
            switch argument {
            case .enumValue(let value), .string(let value):
                raw = value
            default:
                return .failure("Invalid 'span' type. Expected string or enum.")
            }
            switch raw {
            case "thisEvent": return .success(.thisEvent)
            case "futureEvents": return .success(.futureEvents)
            default:
                return .failure("Unknown 'span' value. Allowed: thisEvent, futureEvents.")
            }
        }

        private static func parseStrictISO8601(_ value: String) -> Date? {
            let formatter = ISO8601DateFormatter()
            formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            if let date = formatter.date(from: value) {
                return date
            }
            formatter.formatOptions = [.withInternetDateTime]
            return formatter.date(from: value)
        }

        private static func makeResult(
            for invocation: ConnectionInvocation,
            status: ConnectionInvocationResult.Status,
            errorMessage: String? = nil,
            result: [String: ArgumentValue] = [:]
        ) -> ConnectionInvocationResult {
            ConnectionInvocationResult(
                invocationId: invocation.invocationId,
                kind: invocation.kind,
                actionName: invocation.action.name,
                status: status,
                result: result,
                errorMessage: errorMessage
            )
        }
    }
    #else
    public func authorizationStatus() async -> ConnectionAuthorizationStatus { .unavailable }

    @discardableResult
    public func requestAuthorization() async throws -> ConnectionAuthorizationStatus { .unavailable }

    public func invoke(_ invocation: ConnectionInvocation) async -> ConnectionInvocationResult {
        ConnectionInvocationResult(
            invocationId: invocation.invocationId,
            kind: .calendar,
            actionName: invocation.action.name,
            status: .executionFailed,
            errorMessage: "EventKit not available on this platform."
        )
    }
    #endif
}
