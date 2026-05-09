import Foundation
#if canImport(EventKit)
@preconcurrency import EventKit
#endif

/// Bridges the user's calendars into `ConvosConnections`.
///
/// EventKit has no true background delivery, so this source relies on two wake-up paths:
/// 1. The host app foregrounds → the source emits a fresh snapshot and subscribes to
///    `EKEventStoreChanged`.
/// 2. A `BGAppRefreshTask` calls `snapshotCurrentWindow()` to capture the latest events
///    without going through the observer loop.
///
/// Each emission carries the full window of events (default: from 1 day ago to 14 days
/// ahead). Sending the whole window rather than deltas keeps agent-side reasoning simple;
/// volume is manageable because calendars change infrequently compared to Health.
public final class CalendarDataSource: DataSource, @unchecked Sendable {
    public let kind: ConnectionKind = .calendar
    public let windowPast: TimeInterval
    public let windowFuture: TimeInterval

    public init(
        windowPast: TimeInterval = 24 * 60 * 60,
        windowFuture: TimeInterval = 14 * 24 * 60 * 60
    ) {
        self.windowPast = windowPast
        self.windowFuture = windowFuture
        #if canImport(EventKit)
        self.state = StateBox()
        #endif
    }

    #if canImport(EventKit)
    private let state: StateBox

    public func authorizationStatus() async -> ConnectionAuthorizationStatus {
        let status = EKEventStore.authorizationStatus(for: .event)
        return Self.map(ekStatus: status)
    }

    @discardableResult
    public func requestAuthorization() async throws -> ConnectionAuthorizationStatus {
        let store = EKEventStore()
        _ = try await store.requestFullAccessToEvents()
        return await authorizationStatus()
    }

    public func authorizationDetails() async -> [AuthorizationDetail] {
        let status = await authorizationStatus()
        return [
            AuthorizationDetail(
                identifier: "event",
                displayName: "Calendar Events",
                status: status,
                note: nil
            ),
        ]
    }

    public func start(emit: @escaping ConnectionPayloadEmitter) async throws {
        try await state.start(emit: emit, windowPast: windowPast, windowFuture: windowFuture)
    }

    public func stop() async {
        await state.stop()
    }

    /// Produces a one-shot snapshot of the current window. Useful for the debug view and
    /// for host-app `BGAppRefreshTask` handlers.
    public func snapshotCurrentWindow() async throws -> CalendarPayload {
        let store = EKEventStore()
        let (start, end) = Self.currentWindow(past: windowPast, future: windowFuture)
        let events = Self.fetchEvents(from: start, to: end, store: store)
        return CalendarPayload(
            summary: Self.summarize(events: events, from: start, to: end),
            events: events,
            rangeStart: start,
            rangeEnd: end
        )
    }

    static func map(ekStatus: EKAuthorizationStatus) -> ConnectionAuthorizationStatus {
        switch ekStatus {
        case .notDetermined:
            return .notDetermined
        case .restricted, .denied:
            return .denied
        case .fullAccess, .authorized:
            return .authorized
        case .writeOnly:
            // We only read events; write-only auth is effectively not-yet-granted for us.
            return .partial(missing: ["read-access"])
        @unknown default:
            return .notDetermined
        }
    }

    static func currentWindow(past: TimeInterval, future: TimeInterval) -> (Date, Date) {
        let now = Date()
        return (now.addingTimeInterval(-past), now.addingTimeInterval(future))
    }

    static func fetchEvents(from start: Date, to end: Date, store: EKEventStore) -> [CalendarEvent] {
        let calendars = store.calendars(for: .event)
        let predicate = store.predicateForEvents(withStart: start, end: end, calendars: calendars)
        let ekEvents = store.events(matching: predicate)
        return ekEvents
            .map(CalendarEventMapper.map(_:))
            .sorted(by: { $0.startDate < $1.startDate })
    }

    static func summarize(events: [CalendarEvent], from start: Date, to end: Date) -> String {
        guard !events.isEmpty else {
            return "No events between \(Self.formatter.string(from: start)) and \(Self.formatter.string(from: end))."
        }
        let next = events.first(where: { $0.startDate >= Date() })
        let count = events.count
        if let next, let title = next.title {
            return "\(count) events in window. Next: \(title) at \(Self.formatter.string(from: next.startDate))."
        }
        return "\(count) events in window."
    }

    /// `ISO8601DateFormatter` is documented thread-safe but doesn't conform to `Sendable`
    /// in the Swift 6 stdlib, so an `nonisolated(unsafe)` is the canonical opt-out.
    nonisolated(unsafe) private static let formatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withFullDate, .withFullTime, .withTimeZone]
        return formatter
    }()

    /// Owns the `EKEventStore`, the `NotificationCenter` observer token, and the emitter.
    private actor StateBox {
        private var store: EKEventStore?
        private var observerToken: NSObjectProtocol?
        private var emitter: ConnectionPayloadEmitter?

        func start(emit: @escaping ConnectionPayloadEmitter, windowPast: TimeInterval, windowFuture: TimeInterval) async throws {
            if store != nil { return }
            let store = EKEventStore()
            self.store = store
            self.emitter = emit

            await emitSnapshot(store: store, windowPast: windowPast, windowFuture: windowFuture)

            observerToken = NotificationCenter.default.addObserver(
                forName: .EKEventStoreChanged,
                object: store,
                queue: nil
            ) { [weak self] _ in
                Task { [weak self] in
                    await self?.handleChanged(windowPast: windowPast, windowFuture: windowFuture)
                }
            }
        }

        func stop() async {
            if let observerToken {
                NotificationCenter.default.removeObserver(observerToken)
            }
            observerToken = nil
            store = nil
            emitter = nil
        }

        private func handleChanged(windowPast: TimeInterval, windowFuture: TimeInterval) async {
            guard let store else { return }
            await emitSnapshot(store: store, windowPast: windowPast, windowFuture: windowFuture)
        }

        private func emitSnapshot(store: EKEventStore, windowPast: TimeInterval, windowFuture: TimeInterval) async {
            let (start, end) = CalendarDataSource.currentWindow(past: windowPast, future: windowFuture)
            let events = CalendarDataSource.fetchEvents(from: start, to: end, store: store)
            let body = CalendarPayload(
                summary: CalendarDataSource.summarize(events: events, from: start, to: end),
                events: events,
                rangeStart: start,
                rangeEnd: end
            )
            emitter?(ConnectionPayload(source: .calendar, body: .calendar(body)))
        }
    }
    #else
    public func authorizationStatus() async -> ConnectionAuthorizationStatus { .unavailable }

    @discardableResult
    public func requestAuthorization() async throws -> ConnectionAuthorizationStatus { .unavailable }

    public func start(emit: @escaping ConnectionPayloadEmitter) async throws {}

    public func stop() async {}

    public func snapshotCurrentWindow() async throws -> CalendarPayload {
        CalendarPayload(summary: "EventKit not available.", events: [], rangeStart: Date(), rangeEnd: Date())
    }
    #endif
}
