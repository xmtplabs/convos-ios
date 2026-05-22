import ConvosConnections
import Foundation
#if canImport(HealthKit)
@preconcurrency import HealthKit

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
