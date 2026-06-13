import Foundation

// MARK: - HealthBackgroundDeliveryGateway

/// Abstraction over `HKHealthStore.enableBackgroundDelivery(for:frequency:)` and its
/// disable counterpart. Lets the subscription manager run on macOS in tests via a
/// recording fake while the real iOS app uses `HKHealthStoreBackgroundDeliveryGateway`
/// (which lives in the `ConvosConnectionsHealth` target so HealthKit symbols only
/// enter the binary when the host opts in to that product).
public protocol HealthBackgroundDeliveryGateway: Sendable {
    /// Enable background delivery for `typeIdentifier` at `frequency`. iOS may downgrade
    /// the requested cadence for object types that don't support sub-hourly updates;
    /// the gateway returns the cadence iOS reports it accepted (matches the request for
    /// supported types). Throwing surfaces `HKHealthStore` errors verbatim.
    func setBackgroundDelivery(
        typeIdentifier: HealthSampleType,
        frequency: HealthBackgroundFrequency
    ) async throws

    /// Disable background delivery for `typeIdentifier`. Called when the last subscription
    /// for the type is removed.
    func disableBackgroundDelivery(
        typeIdentifier: HealthSampleType
    ) async throws
}

// MARK: - HealthBackfillReader

/// Reads a one-shot batch of HealthKit samples for one `HealthSampleType` over a
/// fixed window, returning the samples plus the `HKQueryAnchor` produced by the
/// underlying anchored object query.
///
/// `HealthBackgroundSubscriptionManager` calls this on every successful subscribe so
/// the agent receives a backfill `ConnectionPayload` before any background-delivery
/// wake-ups. The anchor is persisted on the subscription row so subsequent wake-ups
/// fetch only new samples since the backfill window's end.
public protocol HealthBackfillReader: Sendable {
    func backfill(
        typeIdentifier: HealthSampleType,
        startDate: Date,
        endDate: Date
    ) async throws -> HealthBackfillResult
}

public struct HealthBackfillResult: Sendable, Equatable {
    public let samples: [HealthSample]
    /// NSKeyed-archived `HKQueryAnchor`. `nil` when HealthKit didn't return one
    /// (e.g. the anchored query failed to encode it). Subsequent delta queries
    /// start from this anchor when present.
    public let anchor: Data?

    public init(samples: [HealthSample], anchor: Data?) {
        self.samples = samples
        self.anchor = anchor
    }
}

// MARK: - HealthDeltaReader

public protocol HealthDeltaReader: Sendable {
    func delta(
        typeIdentifier: HealthSampleType,
        anchor: Data?
    ) async throws -> HealthDeltaResult
}

public struct HealthDeltaResult: Sendable, Equatable {
    public let samples: [HealthSample]
    /// NSKeyed-archived `HKQueryAnchor` produced by the anchored query. Persisted on
    /// the subscription row so the next delta starts from here.
    public let anchor: Data?

    public init(samples: [HealthSample], anchor: Data?) {
        self.samples = samples
        self.anchor = anchor
    }
}

// MARK: - HealthBackgroundObserverRegistrar

public protocol HealthBackgroundObserverRegistrar: Sendable {
    /// Begin observing `typeIdentifier`. The handler is invoked on every observer fire,
    /// possibly concurrently with other types. Must be idempotent: calling `start` for a
    /// type that's already being observed updates the handler without leaking queries.
    func start(
        typeIdentifier: HealthSampleType,
        onFire: @escaping @Sendable () async -> Void
    ) async throws

    /// Stop observing `typeIdentifier`. Idempotent — no-op when the type isn't observed.
    func stop(typeIdentifier: HealthSampleType) async
}
