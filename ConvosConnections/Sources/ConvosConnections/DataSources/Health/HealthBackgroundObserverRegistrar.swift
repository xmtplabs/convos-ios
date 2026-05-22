import ConvosConnections
import Foundation
#if canImport(HealthKit)
@preconcurrency import HealthKit

/// `HKObserverQuery`-backed registrar.
public actor HKHealthStoreObserverRegistrar: HealthBackgroundObserverRegistrar {
    private let store: HKHealthStore
    private var queries: [HealthSampleType: HKObserverQuery] = [:]

    public init(store: HKHealthStore = HKHealthStore()) {
        self.store = store
    }

    public func start(
        typeIdentifier: HealthSampleType,
        onFire: @escaping @Sendable () async -> Void
    ) async throws {
        guard let sampleType = typeIdentifier.hkSampleType else {
            throw RegistrarError.unsupportedType(typeIdentifier.rawValue)
        }
        if let existing = queries[typeIdentifier] {
            store.stop(existing)
            queries[typeIdentifier] = nil
        }
        let query = HKObserverQuery(sampleType: sampleType, predicate: nil) { _, completion, _ in
            let wrappedCompletion = UncheckedSendableBox(completion)
            Task {
                await onFire()
                wrappedCompletion.value()
            }
        }
        store.execute(query)
        queries[typeIdentifier] = query
    }

    public func stop(typeIdentifier: HealthSampleType) async {
        guard let query = queries.removeValue(forKey: typeIdentifier) else { return }
        store.stop(query)
    }

    public enum RegistrarError: Error, Equatable {
        case unsupportedType(String)
    }
}

#endif
