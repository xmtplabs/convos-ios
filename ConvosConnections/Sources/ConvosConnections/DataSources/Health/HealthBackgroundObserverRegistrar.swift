import Foundation
#if canImport(HealthKit)
@preconcurrency import HealthKit
#endif

/// Owns the per-`HealthSampleType` `HKObserverQuery` lifecycle.
///
/// The routine asks the registrar to start observing a type when at least one
/// subscription exists; the registrar invokes `onFire` whenever HealthKit reports new
/// data for that type. Tests use `RecordingHealthBackgroundObserverRegistrar` so the
/// routine's fan-out logic runs on macOS without HealthKit.
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

#if canImport(HealthKit)

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
