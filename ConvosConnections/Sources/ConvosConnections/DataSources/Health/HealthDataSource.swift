import Foundation
#if canImport(HealthKit)
@preconcurrency import HealthKit
#endif

/// Bridges HealthKit into `ConvosConnections`.
///
/// Responsibilities:
/// - Request read authorization for a curated set of health types.
/// - Register observer queries with background delivery so the host app wakes when
///   new samples arrive. The host app must have the `healthkit` background mode
///   entitlement and the `NSHealthShareUsageDescription` key set in `Info.plist`.
/// - On each observer wake-up, run anchored queries against the enabled types and
///   aggregate the deltas into a single `HealthPayload`.
///
/// Volume control: raw heart-rate samples are intentionally **not** included. The source
/// aggregates into digest-style values (daily totals, per-workout summaries, sleep
/// duration) to keep per-payload size small and avoid flooding conversations.
public final class HealthDataSource: DataSource, @unchecked Sendable {
    public let kind: ConnectionKind = .health

    #if canImport(HealthKit)
    private let store: HKHealthStore
    private let types: [HealthSampleType]
    private let state: StateBox = StateBox()

    public init(types: [HealthSampleType] = HealthSampleType.defaultSet) {
        self.store = HKHealthStore()
        self.types = types
    }

    public func authorizationStatus() async -> ConnectionAuthorizationStatus {
        guard HKHealthStore.isHealthDataAvailable() else { return .unavailable }
        let objectTypes = Set(types.compactMap { $0.hkSampleType })
        guard !objectTypes.isEmpty else { return .unavailable }

        // `statusForAuthorizationRequest` tells us whether we still need to prompt. For
        // read-only types, iOS deliberately does not expose the per-type grant decision,
        // so `authorizationStatus(for:)` would always report `.notDetermined` here — hence
        // the request-status API is the only reliable "has the user answered yet" signal.
        do {
            let requestStatus = try await store.statusForAuthorizationRequest(toShare: [], read: objectTypes)
            switch requestStatus {
            case .shouldRequest:
                return .notDetermined
            case .unnecessary:
                // The user has been asked. Actual read grants are hidden by iOS, but we can
                // at least say "permission flow is complete." The source's `note` field on
                // per-type details surfaces the caveat to the UI.
                return .authorized
            case .unknown:
                return .notDetermined
            @unknown default:
                return .notDetermined
            }
        } catch {
            return .notDetermined
        }
    }

    public func authorizationDetails() async -> [AuthorizationDetail] {
        guard HKHealthStore.isHealthDataAvailable() else { return [] }
        var results: [AuthorizationDetail] = []
        for type in types {
            guard let hkType = type.hkSampleType else {
                results.append(
                    AuthorizationDetail(
                        identifier: type.rawValue,
                        displayName: type.displayName,
                        status: .unavailable
                    )
                )
                continue
            }
            let status = await perTypeStatus(for: hkType)
            results.append(
                AuthorizationDetail(
                    identifier: type.rawValue,
                    displayName: type.displayName,
                    status: status,
                    note: status == .authorized ? Self.readAccessNote : nil
                )
            )
        }
        return results
    }

    private func perTypeStatus(for type: HKObjectType) async -> ConnectionAuthorizationStatus {
        do {
            let requestStatus = try await store.statusForAuthorizationRequest(toShare: [], read: [type])
            switch requestStatus {
            case .shouldRequest: return .notDetermined
            case .unnecessary: return .authorized
            case .unknown: return .notDetermined
            @unknown default: return .notDetermined
            }
        } catch {
            return .notDetermined
        }
    }

    private static let readAccessNote: String = "iOS hides the actual read grant for privacy. Check Settings › Privacy & Security › Health to see which types you allowed."

    @discardableResult
    public func requestAuthorization() async throws -> ConnectionAuthorizationStatus {
        guard HKHealthStore.isHealthDataAvailable() else { return .unavailable }
        let objectTypes = Set(types.compactMap { $0.hkSampleType })
        guard !objectTypes.isEmpty else { return .unavailable }
        try await store.requestAuthorization(toShare: [], read: objectTypes)
        return await authorizationStatus()
    }

    public func start(emit: @escaping ConnectionPayloadEmitter) async throws {
        guard HKHealthStore.isHealthDataAvailable() else { return }
        await state.setEmitter(emit)
        await state.startQueries(store: store, types: types)
    }

    public func stop() async {
        await state.stop(store: store)
    }

    /// Runs a one-shot digest across the last 24 hours. Useful for the debug view.
    public func snapshotLast24Hours() async throws -> HealthPayload {
        let now = Date()
        let start = now.addingTimeInterval(-24 * 60 * 60)
        let samples = try await fetchSamples(from: start, to: now)
        return HealthPayload(
            summary: Self.summarize(samples: samples, from: start, to: now),
            samples: samples,
            rangeStart: start,
            rangeEnd: now
        )
    }

    private func fetchSamples(from start: Date, to end: Date) async throws -> [HealthSample] {
        var all: [HealthSample] = []
        for type in types {
            guard let hkType = type.hkSampleType else { continue }
            let predicate = HKQuery.predicateForSamples(withStart: start, end: end)
            let fetched: [HealthSample] = try await withCheckedThrowingContinuation { continuation in
                let query = HKSampleQuery(
                    sampleType: hkType,
                    predicate: predicate,
                    limit: HKObjectQueryNoLimit,
                    sortDescriptors: [NSSortDescriptor(key: HKSampleSortIdentifierStartDate, ascending: true)]
                ) { _, samples, error in
                    if let error {
                        continuation.resume(throwing: error)
                        return
                    }
                    let mapped = (samples ?? []).compactMap { HealthSampleMapper.map($0, as: type) }
                    continuation.resume(returning: mapped)
                }
                store.execute(query)
            }
            all.append(contentsOf: fetched)
        }
        return all.sorted(by: { $0.startDate < $1.startDate })
    }

    private static func summarize(samples: [HealthSample], from start: Date, to end: Date) -> String {
        guard !samples.isEmpty else {
            return "No new health data between \(Self.format(start)) and \(Self.format(end))."
        }
        var byType: [HealthSampleType: [HealthSample]] = [:]
        for sample in samples {
            byType[sample.type, default: []].append(sample)
        }
        let parts = byType.keys.sorted(by: { $0.rawValue < $1.rawValue }).map { type -> String in
            let entries = byType[type] ?? []
            let total = entries.reduce(0.0) { $0 + $1.value }
            let unit = entries.first?.unit ?? ""
            return "\(type.rawValue): \(entries.count) samples, total \(Self.formatNumber(total)) \(unit)".trimmingCharacters(in: .whitespaces)
        }
        return parts.joined(separator: "; ")
    }

    private static let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .short
        formatter.timeStyle = .short
        return formatter
    }()

    private static func format(_ date: Date) -> String { dateFormatter.string(from: date) }

    private static func formatNumber(_ value: Double) -> String {
        String(format: "%.1f", value)
    }

    /// Actor that owns the per-instance mutable state (observer queries + emitter) so
    /// the surrounding class can remain `@unchecked Sendable` without data races.
    private actor StateBox {
        private var emitter: ConnectionPayloadEmitter?
        private var observerQueries: [HKObserverQuery] = []
        private var lastFetch: Date = .distantPast

        func setEmitter(_ emitter: @escaping ConnectionPayloadEmitter) {
            self.emitter = emitter
        }

        func startQueries(store: HKHealthStore, types: [HealthSampleType]) async {
            guard observerQueries.isEmpty else { return }
            for type in types {
                guard let hkType = type.hkSampleType else { continue }
                let query = HKObserverQuery(sampleType: hkType, predicate: nil) { [weak self] _, completion, _ in
                    let wrappedCompletion = UncheckedSendableBox(completion)
                    Task { [weak self] in
                        await self?.handleObserverFired(store: store, types: types)
                        wrappedCompletion.value()
                    }
                }
                store.execute(query)
                observerQueries.append(query)
                do {
                    try await store.enableBackgroundDelivery(for: hkType, frequency: .hourly)
                } catch {
                    // Background delivery is best-effort; a failure here still leaves the
                    // foreground observer query active.
                }
            }
        }

        func stop(store: HKHealthStore) async {
            for query in observerQueries {
                store.stop(query)
            }
            observerQueries.removeAll()
            emitter = nil
        }

        private func handleObserverFired(store: HKHealthStore, types: [HealthSampleType]) async {
            let now = Date()
            let start = lastFetch == .distantPast ? now.addingTimeInterval(-24 * 60 * 60) : lastFetch
            lastFetch = now
            do {
                let samples = try await Self.fetchSamples(store: store, types: types, from: start, to: now)
                guard !samples.isEmpty else { return }
                let body = HealthPayload(
                    summary: HealthDataSource.summarize(samples: samples, from: start, to: now),
                    samples: samples,
                    rangeStart: start,
                    rangeEnd: now
                )
                let payload = ConnectionPayload(source: .health, body: .health(body))
                emitter?(payload)
            } catch {
                // Observer fires may race during low-memory conditions; silently skip on error.
            }
        }

        private static func fetchSamples(store: HKHealthStore, types: [HealthSampleType], from start: Date, to end: Date) async throws -> [HealthSample] {
            var all: [HealthSample] = []
            for type in types {
                guard let hkType = type.hkSampleType else { continue }
                let predicate = HKQuery.predicateForSamples(withStart: start, end: end)
                let fetched: [HealthSample] = try await withCheckedThrowingContinuation { continuation in
                    let query = HKSampleQuery(
                        sampleType: hkType,
                        predicate: predicate,
                        limit: HKObjectQueryNoLimit,
                        sortDescriptors: [NSSortDescriptor(key: HKSampleSortIdentifierStartDate, ascending: true)]
                    ) { _, samples, error in
                        if let error {
                            continuation.resume(throwing: error)
                            return
                        }
                        let mapped = (samples ?? []).compactMap { HealthSampleMapper.map($0, as: type) }
                        continuation.resume(returning: mapped)
                    }
                    store.execute(query)
                }
                all.append(contentsOf: fetched)
            }
            return all.sorted(by: { $0.startDate < $1.startDate })
        }
    }
    #else
    public init(types: [HealthSampleType] = HealthSampleType.defaultSet) {}

    public func authorizationStatus() async -> ConnectionAuthorizationStatus { .unavailable }

    @discardableResult
    public func requestAuthorization() async throws -> ConnectionAuthorizationStatus { .unavailable }

    public func start(emit: @escaping ConnectionPayloadEmitter) async throws {}

    public func stop() async {}

    public func snapshotLast24Hours() async throws -> HealthPayload {
        HealthPayload(
            summary: "HealthKit not available on this platform.",
            samples: [],
            rangeStart: Date(),
            rangeEnd: Date()
        )
    }
    #endif
}

public extension HealthSampleType {
    /// The default set of types the source requests. Heart rate is deliberately omitted
    /// to avoid high-volume streaming; HRV SDNN is used instead as a lower-frequency signal.
    static var defaultSet: [HealthSampleType] {
        [
            .workout,
            .sleepAnalysis,
            .stepCount,
            .heartRateVariabilitySDNN,
            .mindfulSession,
            .activeEnergyBurned,
            .distanceWalkingRunning,
        ]
    }
}
