import Foundation
#if canImport(HealthKit)
@preconcurrency import HealthKit
#endif

/// Write-side counterpart to `HealthDataSource`.
///
/// Supports `log_water`, `log_caffeine`, `log_mindful_minutes`. Requires the
/// `NSHealthUpdateUsageDescription` Info.plist key and a fresh `requestAuthorization`
/// call listing the three share types. Authorization is handled separately from the read
/// flow so writes don't implicitly request read access and vice versa.
public final class HealthDataSink: DataSink, @unchecked Sendable {
    public let kind: ConnectionKind = .health

    public init() {
        #if canImport(HealthKit)
        self.store = HKHealthStore()
        #else
        // Keep the property out of the macOS stub build.
        #endif
    }

    public func actionSchemas() async -> [ActionSchema] {
        HealthActionSchemas.all
    }

    #if canImport(HealthKit)
    private let store: HKHealthStore

    public func authorizationStatus() async -> ConnectionAuthorizationStatus {
        guard HKHealthStore.isHealthDataAvailable() else { return .unavailable }
        let shareTypes = Self.writableSampleTypes()
        guard !shareTypes.isEmpty else { return .unavailable }

        let unauthorized = shareTypes.filter { store.authorizationStatus(for: $0) == .notDetermined }
        let denied = shareTypes.filter { store.authorizationStatus(for: $0) == .sharingDenied }

        if !unauthorized.isEmpty { return .notDetermined }
        if denied.count == shareTypes.count { return .denied }
        if !denied.isEmpty {
            let missing = denied.compactMap { ($0 as? HKQuantityType)?.identifier ?? ($0 as? HKCategoryType)?.identifier }
            return .partial(missing: missing)
        }
        return .authorized
    }

    @discardableResult
    public func requestAuthorization() async throws -> ConnectionAuthorizationStatus {
        let shareTypes = Self.writableSampleTypes()
        guard !shareTypes.isEmpty else { return .unavailable }
        try await store.requestAuthorization(toShare: shareTypes, read: [])
        return await authorizationStatus()
    }

    public func invoke(_ invocation: ConnectionInvocation) async -> ConnectionInvocationResult {
        switch invocation.action.name {
        case HealthActionSchemas.logWater.actionName:
            return await logWater(invocation)
        case HealthActionSchemas.logCaffeine.actionName:
            return await logCaffeine(invocation)
        case HealthActionSchemas.logMindfulMinutes.actionName:
            return await logMindfulMinutes(invocation)
        default:
            return Self.makeResult(
                for: invocation,
                status: .unknownAction,
                errorMessage: "Health sink does not know action '\(invocation.action.name)'."
            )
        }
    }

    private func logWater(_ invocation: ConnectionInvocation) async -> ConnectionInvocationResult {
        let args = invocation.action.arguments
        guard let type = HKQuantityType.quantityType(forIdentifier: .dietaryWater) else {
            return Self.makeResult(for: invocation, status: .executionFailed, errorMessage: "dietaryWater type unavailable on this platform.")
        }
        guard store.authorizationStatus(for: type) == .sharingAuthorized else {
            return Self.makeResult(for: invocation, status: .authorizationDenied, errorMessage: "Water sharing is not granted.")
        }
        guard let quantityValue = args["quantity"]?.doubleArgumentValue else {
            return Self.makeResult(for: invocation, status: .executionFailed, errorMessage: "Missing required argument 'quantity'.")
        }
        guard let unitArg = args["unit"]?.enumRawValue ?? args["unit"]?.stringValue,
              let unit = Self.volumeUnit(from: unitArg) else {
            return Self.makeResult(for: invocation, status: .executionFailed, errorMessage: "Missing or invalid 'unit'. Allowed: oz, mL, L.")
        }

        let date = Self.resolveDate(args["date"]) ?? Date()
        let quantity = HKQuantity(unit: unit, doubleValue: quantityValue)
        let sample = HKQuantitySample(type: type, quantity: quantity, start: date, end: date)

        do {
            try await store.save(sample)
        } catch {
            return Self.makeResult(for: invocation, status: .executionFailed, errorMessage: error.localizedDescription)
        }
        return Self.makeResult(for: invocation, status: .success, result: ["sampleId": .string(sample.uuid.uuidString)])
    }

    private func logCaffeine(_ invocation: ConnectionInvocation) async -> ConnectionInvocationResult {
        let args = invocation.action.arguments
        guard let type = HKQuantityType.quantityType(forIdentifier: .dietaryCaffeine) else {
            return Self.makeResult(for: invocation, status: .executionFailed, errorMessage: "dietaryCaffeine type unavailable on this platform.")
        }
        guard store.authorizationStatus(for: type) == .sharingAuthorized else {
            return Self.makeResult(for: invocation, status: .authorizationDenied, errorMessage: "Caffeine sharing is not granted.")
        }
        guard let milligrams = args["milligrams"]?.doubleArgumentValue else {
            return Self.makeResult(for: invocation, status: .executionFailed, errorMessage: "Missing required argument 'milligrams'.")
        }
        let date = Self.resolveDate(args["date"]) ?? Date()
        let quantity = HKQuantity(unit: .gramUnit(with: .milli), doubleValue: milligrams)
        let sample = HKQuantitySample(type: type, quantity: quantity, start: date, end: date)

        do {
            try await store.save(sample)
        } catch {
            return Self.makeResult(for: invocation, status: .executionFailed, errorMessage: error.localizedDescription)
        }
        return Self.makeResult(for: invocation, status: .success, result: ["sampleId": .string(sample.uuid.uuidString)])
    }

    private func logMindfulMinutes(_ invocation: ConnectionInvocation) async -> ConnectionInvocationResult {
        let args = invocation.action.arguments
        guard let type = HKObjectType.categoryType(forIdentifier: .mindfulSession) else {
            return Self.makeResult(for: invocation, status: .executionFailed, errorMessage: "mindfulSession type unavailable on this platform.")
        }
        guard store.authorizationStatus(for: type) == .sharingAuthorized else {
            return Self.makeResult(for: invocation, status: .authorizationDenied, errorMessage: "Mindful session sharing is not granted.")
        }
        guard let start = Self.resolveDate(args["startDate"]),
              let end = Self.resolveDate(args["endDate"]),
              end > start else {
            return Self.makeResult(for: invocation, status: .executionFailed, errorMessage: "Valid 'startDate' and 'endDate' (with end > start) are required.")
        }
        let sample = HKCategorySample(type: type, value: HKCategoryValue.notApplicable.rawValue, start: start, end: end)

        do {
            try await store.save(sample)
        } catch {
            return Self.makeResult(for: invocation, status: .executionFailed, errorMessage: error.localizedDescription)
        }
        return Self.makeResult(for: invocation, status: .success, result: ["sampleId": .string(sample.uuid.uuidString)])
    }

    private static func writableSampleTypes() -> Set<HKSampleType> {
        var set: Set<HKSampleType> = []
        if let type = HKQuantityType.quantityType(forIdentifier: .dietaryWater) { set.insert(type) }
        if let type = HKQuantityType.quantityType(forIdentifier: .dietaryCaffeine) { set.insert(type) }
        if let type = HKObjectType.categoryType(forIdentifier: .mindfulSession) { set.insert(type) }
        return set
    }

    private static func volumeUnit(from raw: String) -> HKUnit? {
        switch raw {
        case "oz": return .fluidOunceUS()
        case "mL": return .literUnit(with: .milli)
        case "L": return .liter()
        default: return nil
        }
    }

    private static func resolveDate(_ argument: ArgumentValue?) -> Date? {
        guard let argument else { return nil }
        if case .iso8601DateTime(let raw) = argument {
            let formatter = ISO8601DateFormatter()
            formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            if let date = formatter.date(from: raw) { return date }
            formatter.formatOptions = [.withInternetDateTime]
            return formatter.date(from: raw)
        }
        if case .date(let date) = argument { return date }
        return nil
    }

    private static func makeResult(
        for invocation: ConnectionInvocation,
        status: ConnectionInvocationResult.Status,
        errorMessage: String? = nil,
        result: [String: ArgumentValue] = [:]
    ) -> ConnectionInvocationResult {
        ConnectionInvocationResult(
            invocationId: invocation.invocationId,
            kind: invocation.kind,
            actionName: invocation.action.name,
            status: status,
            result: result,
            errorMessage: errorMessage
        )
    }
    #else
    public func authorizationStatus() async -> ConnectionAuthorizationStatus { .unavailable }

    @discardableResult
    public func requestAuthorization() async throws -> ConnectionAuthorizationStatus { .unavailable }

    public func invoke(_ invocation: ConnectionInvocation) async -> ConnectionInvocationResult {
        ConnectionInvocationResult(
            invocationId: invocation.invocationId,
            kind: .health,
            actionName: invocation.action.name,
            status: .executionFailed,
            errorMessage: "HealthKit not available on this platform."
        )
    }
    #endif
}

private extension ArgumentValue {
    /// Permissive accessor that accepts either `.double` or `.int` (coerced to Double).
    var doubleArgumentValue: Double? {
        switch self {
        case .double(let value): return value
        case .int(let value): return Double(value)
        default: return nil
        }
    }
}
