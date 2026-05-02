import Foundation
#if canImport(HealthKit)
@preconcurrency import HealthKit
#endif

/// Abstraction over `HKHealthStore.enableBackgroundDelivery(for:frequency:)` and its
/// disable counterpart. Lets the subscription manager run on macOS in tests via a
/// recording fake while the real iOS app uses `HKHealthStoreBackgroundDeliveryGateway`.
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

#if canImport(HealthKit)

/// `HKHealthStore`-backed gateway. Picks the right `HKObjectType` for the
/// `HealthSampleType` raw value and translates `HealthBackgroundFrequency` to iOS's
/// `HKUpdateFrequency`.
public struct HKHealthStoreBackgroundDeliveryGateway: HealthBackgroundDeliveryGateway {
    private let store: HKHealthStore

    public init(store: HKHealthStore = HKHealthStore()) {
        self.store = store
    }

    public func setBackgroundDelivery(
        typeIdentifier: HealthSampleType,
        frequency: HealthBackgroundFrequency
    ) async throws {
        guard let objectType = typeIdentifier.hkSampleType else {
            throw GatewayError.unsupportedType(typeIdentifier.rawValue)
        }
        try await store.enableBackgroundDelivery(
            for: objectType,
            frequency: frequency.hkUpdateFrequency
        )
    }

    public func disableBackgroundDelivery(typeIdentifier: HealthSampleType) async throws {
        guard let objectType = typeIdentifier.hkSampleType else {
            throw GatewayError.unsupportedType(typeIdentifier.rawValue)
        }
        try await store.disableBackgroundDelivery(for: objectType)
    }

    public enum GatewayError: Error, Equatable {
        case unsupportedType(String)
    }
}

private extension HealthBackgroundFrequency {
    var hkUpdateFrequency: HKUpdateFrequency {
        switch self {
        case .immediate: return .immediate
        case .hourly: return .hourly
        case .daily: return .daily
        case .weekly: return .weekly
        }
    }
}

#endif
