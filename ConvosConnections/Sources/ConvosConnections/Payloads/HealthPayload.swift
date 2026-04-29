import Foundation

/// A batch of HealthKit samples aggregated into a single payload.
///
/// `HealthDataSource` produces one of these per observation wake-up. Volume control lives
/// at the source — raw heart-rate streams are *not* sent; the source aggregates into
/// digest-style values (daily totals, per-workout summaries, sleep duration, etc.).
public struct HealthPayload: Codable, Sendable, Equatable {
    public static let currentSchemaVersion: Int = 1

    public let schemaVersion: Int
    public let summary: String
    public let samples: [HealthSample]
    public let rangeStart: Date
    public let rangeEnd: Date

    public init(
        schemaVersion: Int = Self.currentSchemaVersion,
        summary: String,
        samples: [HealthSample],
        rangeStart: Date,
        rangeEnd: Date
    ) {
        self.schemaVersion = schemaVersion
        self.summary = summary
        self.samples = samples
        self.rangeStart = rangeStart
        self.rangeEnd = rangeEnd
    }
}

public struct HealthSample: Codable, Sendable, Equatable {
    public let type: HealthSampleType
    public let startDate: Date
    public let endDate: Date
    public let value: Double
    public let unit: String
    public let metadata: [String: String]?

    public init(
        type: HealthSampleType,
        startDate: Date,
        endDate: Date,
        value: Double,
        unit: String,
        metadata: [String: String]? = nil
    ) {
        self.type = type
        self.startDate = startDate
        self.endDate = endDate
        self.value = value
        self.unit = unit
        self.metadata = metadata
    }
}

public enum HealthSampleType: String, Codable, Sendable, CaseIterable {
    case workout
    case sleepAnalysis = "sleep_analysis"
    case stepCount = "step_count"
    case heartRateVariabilitySDNN = "hrv_sdnn"
    case mindfulSession = "mindful_session"
    case activeEnergyBurned = "active_energy_burned"
    case distanceWalkingRunning = "distance_walking_running"

    public var displayName: String {
        switch self {
        case .workout: return "Workouts"
        case .sleepAnalysis: return "Sleep"
        case .stepCount: return "Steps"
        case .heartRateVariabilitySDNN: return "Heart Rate Variability"
        case .mindfulSession: return "Mindful Minutes"
        case .activeEnergyBurned: return "Active Energy"
        case .distanceWalkingRunning: return "Walking + Running Distance"
        }
    }
}
