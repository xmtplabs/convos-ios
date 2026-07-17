import Foundation

/// Unified authorization status across all data sources.
///
/// Individual sources (HealthKit, EventKit, CLLocationManager, etc.) each have their own
/// native status types. Each `DataSource` maps its native status into this common shape.
public enum ConnectionAuthorizationStatus: Sendable, Hashable {
    /// User has not yet been prompted.
    case notDetermined
    /// User denied access, or the source is restricted by MDM / parental controls.
    case denied
    /// All requested data types are authorized.
    case authorized
    /// Some requested data types are authorized; others are denied or not determined.
    /// `missing` lists the per-source identifiers the user has not granted.
    case partial(missing: [String])
    /// Source is unavailable on this device (e.g., HealthKit on a device without it).
    case unavailable
}

public extension ConnectionAuthorizationStatus {
    /// Whether the source can deliver any data in this state.
    var canDeliverData: Bool {
        switch self {
        case .authorized, .partial:
            return true
        case .notDetermined, .denied, .unavailable:
            return false
        }
    }
}
