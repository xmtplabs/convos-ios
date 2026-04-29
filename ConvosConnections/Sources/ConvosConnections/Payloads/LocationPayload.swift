import Foundation

/// Location events captured by `LocationDataSource` since the last emission.
///
/// Two classes of event are mixed into one payload:
/// - **Significant location changes** — fire roughly when the user moves 500m+, wake the
///   app from the background (or from a terminated state).
/// - **Visits** — fire on arrival at and departure from places the user spends time at.
///
/// Both are low-frequency, low-battery signals intentionally — the source does *not* emit
/// high-frequency raw location samples, because a human conversation can't usefully consume
/// them and XMTP fan-out would be wasteful.
public struct LocationPayload: Codable, Sendable, Equatable {
    public static let currentSchemaVersion: Int = 1

    public let schemaVersion: Int
    public let summary: String
    public let events: [LocationEvent]
    public let capturedAt: Date

    public init(
        schemaVersion: Int = Self.currentSchemaVersion,
        summary: String,
        events: [LocationEvent],
        capturedAt: Date = Date()
    ) {
        self.schemaVersion = schemaVersion
        self.summary = summary
        self.events = events
        self.capturedAt = capturedAt
    }
}

public struct LocationEvent: Codable, Sendable, Equatable, Identifiable {
    public let id: UUID
    public let type: LocationEventType
    public let latitude: Double
    public let longitude: Double
    /// Radius (in meters) of uncertainty for the coordinate. Negative if invalid.
    public let horizontalAccuracy: Double
    /// The moment the event occurred (visit arrival, visit departure, or sample timestamp).
    public let eventDate: Date
    /// Only set for `.visitArrival` / `.visitDeparture`.
    public let arrivalDate: Date?
    /// Only set for `.visitDeparture`. `nil` for an active visit.
    public let departureDate: Date?

    public init(
        id: UUID = UUID(),
        type: LocationEventType,
        latitude: Double,
        longitude: Double,
        horizontalAccuracy: Double,
        eventDate: Date,
        arrivalDate: Date? = nil,
        departureDate: Date? = nil
    ) {
        self.id = id
        self.type = type
        self.latitude = latitude
        self.longitude = longitude
        self.horizontalAccuracy = horizontalAccuracy
        self.eventDate = eventDate
        self.arrivalDate = arrivalDate
        self.departureDate = departureDate
    }
}

public enum LocationEventType: String, Codable, Sendable {
    case significantChange = "significant_change"
    case visitArrival = "visit_arrival"
    case visitDeparture = "visit_departure"
}
