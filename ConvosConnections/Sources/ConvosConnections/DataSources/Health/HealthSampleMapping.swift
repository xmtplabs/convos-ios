import Foundation
#if canImport(HealthKit)
@preconcurrency import HealthKit
#endif

/// Translates HealthKit sample types into `HealthSampleType` and back.
///
/// Split from `HealthDataSource` so the mapping logic is unit-testable on iOS and so the
/// platform-conditional code stays localized.
enum HealthSampleMapper {
    #if canImport(HealthKit)
    static func map(_ sample: HKSample, as type: HealthSampleType) -> HealthSample? {
        switch type {
        case .workout:
            guard let workout = sample as? HKWorkout else { return nil }
            return HealthSample(
                type: .workout,
                startDate: workout.startDate,
                endDate: workout.endDate,
                value: workout.duration,
                unit: "seconds",
                metadata: ["activityType": "\(workout.workoutActivityType.rawValue)"]
            )
        case .sleepAnalysis, .mindfulSession:
            guard let category = sample as? HKCategorySample else { return nil }
            return HealthSample(
                type: type,
                startDate: category.startDate,
                endDate: category.endDate,
                value: category.endDate.timeIntervalSince(category.startDate),
                unit: "seconds",
                metadata: ["value": "\(category.value)"]
            )
        case .stepCount, .heartRateVariabilitySDNN, .activeEnergyBurned, .distanceWalkingRunning:
            guard let quantity = sample as? HKQuantitySample else { return nil }
            guard let unit = type.preferredUnit else { return nil }
            return HealthSample(
                type: type,
                startDate: quantity.startDate,
                endDate: quantity.endDate,
                value: quantity.quantity.doubleValue(for: unit),
                unit: type.unitDisplayString,
                metadata: nil
            )
        }
    }
    #endif
}

extension HealthSampleType {
    #if canImport(HealthKit)
    var hkSampleType: HKSampleType? {
        switch self {
        case .workout:
            return HKObjectType.workoutType()
        case .sleepAnalysis:
            return HKObjectType.categoryType(forIdentifier: .sleepAnalysis)
        case .stepCount:
            return HKObjectType.quantityType(forIdentifier: .stepCount)
        case .heartRateVariabilitySDNN:
            return HKObjectType.quantityType(forIdentifier: .heartRateVariabilitySDNN)
        case .mindfulSession:
            return HKObjectType.categoryType(forIdentifier: .mindfulSession)
        case .activeEnergyBurned:
            return HKObjectType.quantityType(forIdentifier: .activeEnergyBurned)
        case .distanceWalkingRunning:
            return HKObjectType.quantityType(forIdentifier: .distanceWalkingRunning)
        }
    }

    var preferredUnit: HKUnit? {
        switch self {
        case .stepCount:
            return .count()
        case .heartRateVariabilitySDNN:
            return .secondUnit(with: .milli)
        case .activeEnergyBurned:
            return .kilocalorie()
        case .distanceWalkingRunning:
            return .meter()
        case .workout, .sleepAnalysis, .mindfulSession:
            return nil
        }
    }
    #endif

    var unitDisplayString: String {
        switch self {
        case .workout, .sleepAnalysis, .mindfulSession:
            return "seconds"
        case .stepCount:
            return "count"
        case .heartRateVariabilitySDNN:
            return "ms"
        case .activeEnergyBurned:
            return "kcal"
        case .distanceWalkingRunning:
            return "m"
        }
    }
}
