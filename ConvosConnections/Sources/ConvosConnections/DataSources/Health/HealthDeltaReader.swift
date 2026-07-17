import ConvosConnections
import Foundation
#if canImport(HealthKit)
@preconcurrency import HealthKit

/// `HKAnchoredObjectQueryDescriptor`-backed delta reader.
public struct HKHealthStoreDeltaReader: HealthDeltaReader {
    private let store: HKHealthStore

    public init(store: HKHealthStore = HKHealthStore()) {
        self.store = store
    }

    public func delta(
        typeIdentifier: HealthSampleType,
        anchor: Data?
    ) async throws -> HealthDeltaResult {
        guard let sampleType = typeIdentifier.hkSampleType else {
            throw ReaderError.unsupportedType(typeIdentifier.rawValue)
        }
        let resolvedAnchor = anchor.flatMap(Self.unarchiveAnchor)
        let descriptor = HKAnchoredObjectQueryDescriptor(
            predicates: [.sample(type: sampleType, predicate: nil)],
            anchor: resolvedAnchor
        )
        let result = try await descriptor.result(for: store)
        let samples = result.addedSamples.compactMap { HealthSampleMapper.map($0, as: typeIdentifier) }
        let archivedAnchor = try? NSKeyedArchiver.archivedData(
            withRootObject: result.newAnchor,
            requiringSecureCoding: true
        )
        return HealthDeltaResult(samples: samples, anchor: archivedAnchor)
    }

    private static func unarchiveAnchor(_ data: Data) -> HKQueryAnchor? {
        try? NSKeyedUnarchiver.unarchivedObject(ofClass: HKQueryAnchor.self, from: data)
    }

    public enum ReaderError: Error, Equatable {
        case unsupportedType(String)
    }
}

#endif
