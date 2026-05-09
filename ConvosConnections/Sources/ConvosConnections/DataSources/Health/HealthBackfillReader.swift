import Foundation
#if canImport(HealthKit)
@preconcurrency import HealthKit
#endif

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

#if canImport(HealthKit)

/// `HKHealthStore`-backed backfill reader. Uses `HKAnchoredObjectQueryDescriptor` so the
/// returned anchor can be reused for future delta queries.
public struct HKHealthStoreBackfillReader: HealthBackfillReader {
    private let store: HKHealthStore

    public init(store: HKHealthStore = HKHealthStore()) {
        self.store = store
    }

    public func backfill(
        typeIdentifier: HealthSampleType,
        startDate: Date,
        endDate: Date
    ) async throws -> HealthBackfillResult {
        guard let sampleType = typeIdentifier.hkSampleType else {
            throw ReaderError.unsupportedType(typeIdentifier.rawValue)
        }
        let predicate = HKQuery.predicateForSamples(withStart: startDate, end: endDate)
        let descriptor = HKAnchoredObjectQueryDescriptor(
            predicates: [.sample(type: sampleType, predicate: predicate)],
            anchor: nil
        )
        let result = try await descriptor.result(for: store)

        let samples = result.addedSamples.compactMap { HealthSampleMapper.map($0, as: typeIdentifier) }
        let archivedAnchor = try? NSKeyedArchiver.archivedData(
            withRootObject: result.newAnchor,
            requiringSecureCoding: true
        )
        return HealthBackfillResult(samples: samples, anchor: archivedAnchor)
    }

    public enum ReaderError: Error, Equatable {
        case unsupportedType(String)
    }
}

#endif
