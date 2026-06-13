import ConvosConnections
import Foundation
#if canImport(HealthKit)
@preconcurrency import HealthKit

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
