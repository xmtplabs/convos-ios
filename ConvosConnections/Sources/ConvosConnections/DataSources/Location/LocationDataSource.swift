import Foundation
#if os(iOS)
@preconcurrency import CoreLocation
#endif

/// Bridges Core Location into `ConvosConnections`.
///
/// Observation strategy (low-battery, wake-friendly):
/// - **Significant location changes** — fire when the user moves ~500m+. iOS wakes the
///   app from the background (or from terminated) to deliver these.
/// - **Visits** — fire on arrival at and departure from places the user lingers at.
///
/// Deliberately does *not* use `startUpdatingLocation`, which drains battery and delivers
/// far more samples than a conversation can usefully consume.
///
/// Authorization model follows Apple's recommended pattern: we request when-in-use first,
/// then request always once when-in-use is granted. Only `authorizedAlways` enables real
/// background wake — `authorizedWhenInUse` degrades to foreground-only observation.
public final class LocationDataSource: DataSource, @unchecked Sendable {
    public let kind: ConnectionKind = .location

    #if os(iOS)
    private let state: StateBox

    public init() {
        self.state = StateBox()
    }

    public func authorizationStatus() async -> ConnectionAuthorizationStatus {
        await state.authorizationStatus()
    }

    @discardableResult
    public func requestAuthorization() async throws -> ConnectionAuthorizationStatus {
        await state.requestAuthorization()
    }

    public func authorizationDetails() async -> [AuthorizationDetail] {
        let status = await authorizationStatus()
        let note: String? = {
            switch status {
            case .partial:
                return "Only \"While Using\" was granted. Background wake on significant-change and visits requires \"Always\" — upgrade in Settings."
            case .authorized:
                return nil
            default:
                return nil
            }
        }()
        return [
            AuthorizationDetail(
                identifier: "location",
                displayName: "Location Access",
                status: status,
                note: note
            ),
        ]
    }

    public func start(emit: @escaping ConnectionPayloadEmitter) async throws {
        await state.start(emit: emit)
    }

    public func stop() async {
        await state.stop()
    }

    // MARK: - Mapping

    static func map(_ status: CLAuthorizationStatus) -> ConnectionAuthorizationStatus {
        switch status {
        case .notDetermined:
            return .notDetermined
        case .restricted, .denied:
            return .denied
        case .authorizedWhenInUse:
            return .partial(missing: ["authorizedAlways"])
        case .authorizedAlways:
            return .authorized
        @unknown default:
            return .notDetermined
        }
    }

    static func summarize(events: [LocationEvent]) -> String {
        guard !events.isEmpty else { return "No new location events." }
        let changeCount = events.filter { $0.type == .significantChange }.count
        let arrivalCount = events.filter { $0.type == .visitArrival }.count
        let departureCount = events.filter { $0.type == .visitDeparture }.count
        var parts: [String] = []
        if changeCount > 0 { parts.append("\(changeCount) significant change\(changeCount == 1 ? "" : "s")") }
        if arrivalCount > 0 { parts.append("\(arrivalCount) arrival\(arrivalCount == 1 ? "" : "s")") }
        if departureCount > 0 { parts.append("\(departureCount) departure\(departureCount == 1 ? "" : "s")") }
        return parts.joined(separator: ", ")
    }

    /// Actor that owns the `CLLocationManager`, its delegate adapter, and the emitter.
    /// Delegate callbacks arrive on the main thread and hop into the actor via `Task {}`.
    private actor StateBox {
        private var manager: CLLocationManager?
        private var delegate: Delegate?
        private var emitter: ConnectionPayloadEmitter?
        /// Waiters keyed by a per-call UUID so a cancelled task only resumes its own
        /// continuation, leaving any concurrent callers waiting for the real callback.
        private var authorizationWaiters: [UUID: CheckedContinuation<Void, Never>] = [:]
        /// Status the caller is waiting to move OFF of. iOS 14+ fires
        /// `locationManagerDidChangeAuthorization` once when the delegate is first
        /// registered — that fire is a no-op for our purposes (status hasn't actually
        /// changed yet), and would otherwise resume the continuation before the system
        /// prompt could even appear.
        private var pendingAuthorizationFrom: CLAuthorizationStatus?

        func authorizationStatus() -> ConnectionAuthorizationStatus {
            let manager = manager ?? createManager()
            return LocationDataSource.map(manager.authorizationStatus)
        }

        func requestAuthorization() async -> ConnectionAuthorizationStatus {
            let manager = manager ?? createManager()

            if manager.authorizationStatus == .notDetermined {
                await waitForAuthorizationChange(from: .notDetermined) {
                    manager.requestWhenInUseAuthorization()
                }
            }
            // Best-effort upgrade to .always. Don't wait for the response: iOS doesn't fire
            // the delegate when the user has previously denied "Always" in Settings, and may
            // defer the upgrade prompt to a later moment in the app's lifecycle. Callers
            // that need .always confirmed can poll `authorizationStatus()` later.
            if manager.authorizationStatus == .authorizedWhenInUse {
                manager.requestAlwaysAuthorization()
            }
            return LocationDataSource.map(manager.authorizationStatus)
        }

        private func waitForAuthorizationChange(
            from initialStatus: CLAuthorizationStatus,
            action: () -> Void
        ) async {
            pendingAuthorizationFrom = initialStatus
            let waiterId = UUID()
            await withTaskCancellationHandler {
                await withCheckedContinuation { continuation in
                    authorizationWaiters[waiterId] = continuation
                    action()
                }
            } onCancel: {
                Task { await self.cancelAuthorizationWaiter(id: waiterId) }
            }
        }

        private func cancelAuthorizationWaiter(id: UUID) {
            authorizationWaiters.removeValue(forKey: id)?.resume()
        }

        func start(emit: @escaping ConnectionPayloadEmitter) {
            self.emitter = emit
            let manager = manager ?? createManager()
            manager.startMonitoringSignificantLocationChanges()
            #if os(iOS)
            manager.startMonitoringVisits()
            #endif
        }

        func stop() {
            manager?.stopMonitoringSignificantLocationChanges()
            #if os(iOS)
            manager?.stopMonitoringVisits()
            #endif
            emitter = nil
        }

        fileprivate func onLocationUpdate(_ locations: [CLLocation]) {
            guard !locations.isEmpty else { return }
            let events = locations.map { location in
                LocationEvent(
                    type: .significantChange,
                    latitude: location.coordinate.latitude,
                    longitude: location.coordinate.longitude,
                    horizontalAccuracy: location.horizontalAccuracy,
                    eventDate: location.timestamp
                )
            }
            emit(events: events)
        }

        fileprivate func onVisit(_ visit: CLVisit) {
            // CoreLocation uses sentinels for unknown times: `Date.distantFuture` means
            // departure hasn't happened, `Date.distantPast` means arrival is unknown. Map
            // those to nil for consumers, and use the observation time for `eventDate`
            // when neither real timestamp is available.
            let arrivalDate: Date? = visit.arrivalDate == Date.distantPast ? nil : visit.arrivalDate
            let departureDate: Date? = visit.departureDate == Date.distantFuture ? nil : visit.departureDate
            let isDeparture = departureDate != nil
            let eventDate = (isDeparture ? departureDate : arrivalDate) ?? Date()
            let event = LocationEvent(
                type: isDeparture ? .visitDeparture : .visitArrival,
                latitude: visit.coordinate.latitude,
                longitude: visit.coordinate.longitude,
                horizontalAccuracy: visit.horizontalAccuracy,
                eventDate: eventDate,
                arrivalDate: arrivalDate,
                departureDate: departureDate
            )
            emit(events: [event])
        }

        fileprivate func onAuthorizationChange() {
            guard let pending = pendingAuthorizationFrom else { return }
            guard manager?.authorizationStatus != pending else { return }
            pendingAuthorizationFrom = nil
            let waiters = authorizationWaiters
            authorizationWaiters = [:]
            for waiter in waiters.values { waiter.resume() }
        }

        private func emit(events: [LocationEvent]) {
            guard let emitter else { return }
            let body = LocationPayload(
                summary: LocationDataSource.summarize(events: events),
                events: events
            )
            emitter(ConnectionPayload(source: .location, body: .location(body)))
        }

        private func createManager() -> CLLocationManager {
            let manager = CLLocationManager()
            let delegate = Delegate(state: self)
            manager.delegate = delegate
            self.manager = manager
            self.delegate = delegate
            return manager
        }
    }

    /// Forwards `CLLocationManagerDelegate` callbacks into the actor. Held strongly by the
    /// actor and referenced weakly here so it doesn't outlive the state.
    private final class Delegate: NSObject, CLLocationManagerDelegate, @unchecked Sendable {
        weak var state: StateBox?

        init(state: StateBox) {
            self.state = state
        }

        func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
            let ref = state
            Task { await ref?.onLocationUpdate(locations) }
        }

        #if os(iOS)
        func locationManager(_ manager: CLLocationManager, didVisit visit: CLVisit) {
            let ref = state
            Task { await ref?.onVisit(visit) }
        }
        #endif

        func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
            let ref = state
            Task { await ref?.onAuthorizationChange() }
        }
    }
    #else
    public init() {}

    public func authorizationStatus() async -> ConnectionAuthorizationStatus { .unavailable }

    @discardableResult
    public func requestAuthorization() async throws -> ConnectionAuthorizationStatus { .unavailable }

    public func start(emit: @escaping ConnectionPayloadEmitter) async throws {}

    public func stop() async {}
    #endif
}
