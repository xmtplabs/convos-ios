import Foundation

/// Current motion activity as reported by the device's motion coprocessor — stationary,
/// walking, running, driving, cycling. Emitted by `MotionDataSource` whenever the activity
/// classification changes.
public struct MotionPayload: Codable, Sendable, Equatable {
    public static let currentSchemaVersion: Int = 1

    public let schemaVersion: Int
    public let summary: String
    public let activity: MotionActivity?
    public let capturedAt: Date

    public init(
        schemaVersion: Int = Self.currentSchemaVersion,
        summary: String,
        activity: MotionActivity?,
        capturedAt: Date = Date()
    ) {
        self.schemaVersion = schemaVersion
        self.summary = summary
        self.activity = activity
        self.capturedAt = capturedAt
    }
}

public struct MotionActivity: Codable, Sendable, Equatable {
    public let type: MotionActivityType
    public let confidence: MotionConfidence
    public let startDate: Date

    public init(type: MotionActivityType, confidence: MotionConfidence, startDate: Date) {
        self.type = type
        self.confidence = confidence
        self.startDate = startDate
    }
}

public enum MotionActivityType: String, Codable, Sendable {
    case stationary
    case walking
    case running
    case automotive
    case cycling
    case unknown
}

public enum MotionConfidence: String, Codable, Sendable {
    case low
    case medium
    case high
}
