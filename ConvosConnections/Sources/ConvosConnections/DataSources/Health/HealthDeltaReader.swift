import Foundation
#if canImport(HealthKit)
@preconcurrency import HealthKit
#endif

/// Reads HealthKit samples that have arrived since a previous `HKQueryAnchor`. The
/// observer routine calls this once per subscription whenever iOS wakes the host app
/// for the corresponding `HealthSampleType`.
///
/// Distinct from `HealthBackfillReader` because the input is a saved anchor (or `nil`
/// for an unbounded first read) rather than a date window. The output is the new
/// samples since that anchor plus the updated anchor to persist.
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

#if canImport(HealthKit)

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
